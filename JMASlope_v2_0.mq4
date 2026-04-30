//+------------------------------------------------------------------+
//|                                              JMASlope_v2_0.mq4    |
//|                          Рефакторинг: Ruslan Kuchma, 2026   |
//|                          Оригинал: TrendLaboratory Ltd., 2005     |
//|                          Алгоритм: Jurik Moving Average (JMA)     |
//+------------------------------------------------------------------+
//| ИЗМЕНЕНИЯ v2.0:                                                   |
//|  - 8-блочная архитектура (OnInit/OnCalculate/#property strict)    |
//|  - ATR нормализация (безразмерный slope, ×1000)                  |
//|  - 8 буферов: 5 экспортных + 3 внутренних                       |
//|  - Строгий anti-repaint (i >= 1, без пересчёта текущего бара)    |
//|  - Оптимизация через prev_calculated                              |
//|  - Выбор Applied Price (Close/Open/High/Low/Median/Typical...)   |
//|  - EMPTY_VALUE для незаполненных данных                           |
//|  - Очистка гистограммы при смене направления                      |
//|  - Валидация входных параметров                                   |
//|  - Комментарии на русском к каждому блоку                        |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| БЛОК 1: #PROPERTY ДИРЕКТИВЫ                                      |
//+------------------------------------------------------------------+
#property copyright "2026, Ruslan Kuchma"
#property link      "https://t.me/RuslanKuchma"
#property version   "2.00"
#property strict                          // Строгий режим компиляции
#property description "JMA Slope с ATR нормализацией"
#property description "Буфер[3] NormSlope — основной для EA через iCustom"

#property indicator_separate_window        // Индикатор в отдельном окне
#property indicator_buffers 8              // 8 буферов (5 экспорт + 3 внутренних)

// --- Визуальные буферы (нормализованная гистограмма) ---
#property indicator_color1 clrBlue         // [0] NormSlope Up (положительный)
#property indicator_color2 clrRed          // [1] NormSlope Down (отрицательный)
#property indicator_width1 3
#property indicator_width2 3

// --- Скрытые буферы для EA (через iCustom) ---
#property indicator_color3 clrNONE         // [2] JMA Value (линия)
#property indicator_color4 clrNONE         // [3] NormSlope (единый буфер)
#property indicator_color5 clrNONE         // [4] RawSlope (сырой наклон)

// --- Внутренние расчётные буферы ---
#property indicator_color6 clrNONE         // [5] fC0 (первый фильтр JMA)
#property indicator_color7 clrNONE         // [6] fA8 (адаптивный компонент)
#property indicator_color8 clrNONE         // [7] fC8 (второй фильтр JMA)

//+------------------------------------------------------------------+
//| БЛОК 2: INPUT ПАРАМЕТРЫ                                          |
//+------------------------------------------------------------------+
input int    JMA_Length     = 3;          // Период JMA (аналог MA, >= 1)
input int    JMA_Phase      = 100;          // Фаза JMA (-100..+100, запаздывание/опережение)
input int    ATR_Period     = 14;         // Период ATR для нормализации
input double NormMultiplier = 1000.0;     // Множитель нормализации (1000 = безразмерный)
input ENUM_APPLIED_PRICE AppliedPrice = PRICE_WEIGHTED; // Тип цены

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И БУФЕРЫ                          |
//+------------------------------------------------------------------+

// --- Экспортируемые буферы (доступны через iCustom) ---
double NormSlopeUpBuf[];    // [0] Гистограмма: положительный нормализованный наклон
double NormSlopeDnBuf[];    // [1] Гистограмма: отрицательный нормализованный наклон
double JMAValueBuf[];       // [2] Значение JMA линии
double NormSlopeBuf[];      // [3] Единый нормализованный наклон (для EA)
double RawSlopeBuf[];       // [4] Сырой наклон: JMA[i] - JMA[i+1]

// --- Внутренние расчётные буферы JMA ---
double fC0Buf[];            // [5] JMA внутренний: первый фильтр
double fA8Buf[];            // [6] JMA внутренний: адаптивный компонент
double fC8Buf[];            // [7] JMA внутренний: второй фильтр

// === Глобальные массивы состояния алгоритма JMA ===
// JMA использует адаптивный медианный фильтр волатильности.
// Эти массивы хранят текущее состояние фильтра между вызовами OnCalculate.
double g_sortedList[128];   // Отсортированный массив для медианного фильтра волатильности
double g_volHistory[128];   // Кольцевой буфер: история средней волатильности (128 образцов)
double g_recentVol[11];     // Кольцевой буфер: недавняя волатильность (10 образцов)
double g_warmupData[62];    // Хранилище цен разогрева (первые 30+ баров)

// === Глобальные скалярные переменные состояния JMA ===
bool   g_isFirstCalc;       // Флаг: первый расчёт после инициализации
int    g_warmupCount;        // Счётчик баров разогрева (0..61)
int    g_mainPhaseCount;     // Счётчик основной фазы расчёта (0..31)
int    g_volHistIdx;         // Индекс в кольцевом буфере g_volHistory
int    g_recentVolIdx;       // Индекс в кольцевом буфере g_recentVol
int    g_volSampleCount;     // Количество накопленных образцов волатильности (0..128)
int    g_listLowBound;       // Нижняя граница активной области g_sortedList
int    g_listHighBound;      // Верхняя граница активной области g_sortedList
int    g_medianHigh;         // Верхний индекс медианного диапазона в g_sortedList
int    g_medianLow;          // Нижний индекс медианного диапазона в g_sortedList
double g_volSum;             // Текущая сумма недавней волатильности (скользящее окно 10)
double g_medianSum;          // Сумма значений в медианном диапазоне
double g_trackHigh;          // Адаптивный верхний трекер цены
double g_trackLow;           // Адаптивный нижний трекер цены

// === Предвычисленные константы JMA (рассчитываются один раз в OnInit) ===
double g_phaseParam;         // Параметр фазы: 0.5..2.5 (из JMA_Phase)
double g_logParam;           // Логарифмический параметр (из JMA_Length)
double g_sqrtParam;          // sqrt(lengthParam) × logParam
double g_lengthDivider;      // lengthParam × 0.9 / (lengthParam × 0.9 + 2.0)

//+------------------------------------------------------------------+
//| БЛОК 4: ИНИЦИАЛИЗАЦИЯ (OnInit)                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Валидация входных параметров ---
   if(JMA_Length < 1)
   {
      Print("[JMASlope v2.0 ERROR] JMA_Length должен быть >= 1, получено: ", JMA_Length);
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(ATR_Period < 1)
   {
      Print("[JMASlope v2.0 ERROR] ATR_Period должен быть >= 1, получено: ", ATR_Period);
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(NormMultiplier <= 0)
   {
      Print("[JMASlope v2.0 ERROR] NormMultiplier должен быть > 0, получено: ", NormMultiplier);
      return(INIT_PARAMETERS_INCORRECT);
   }

   // --- Регистрация всех 8 буферов ---
   IndicatorBuffers(8);

   SetIndexBuffer(0, NormSlopeUpBuf);
   SetIndexBuffer(1, NormSlopeDnBuf);
   SetIndexBuffer(2, JMAValueBuf);
   SetIndexBuffer(3, NormSlopeBuf);
   SetIndexBuffer(4, RawSlopeBuf);
   SetIndexBuffer(5, fC0Buf);
   SetIndexBuffer(6, fA8Buf);
   SetIndexBuffer(7, fC8Buf);

   // --- Настройка отрисовки ---
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, 3);  // Зелёная гистограмма вверх
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, 3);  // Красная гистограмма вниз
   SetIndexStyle(2, DRAW_NONE);    // JMA Value — скрытый
   SetIndexStyle(3, DRAW_NONE);    // NormSlope — скрытый
   SetIndexStyle(4, DRAW_NONE);    // RawSlope — скрытый
   SetIndexStyle(5, DRAW_NONE);    // fC0 — внутренний
   SetIndexStyle(6, DRAW_NONE);    // fA8 — внутренний
   SetIndexStyle(7, DRAW_NONE);    // fC8 — внутренний

   // --- EMPTY_VALUE для визуальных и экспортных буферов ---
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, EMPTY_VALUE);
   SetIndexEmptyValue(3, 0.0);   // NormSlope: 0 = нейтрально (для EA)
   SetIndexEmptyValue(4, 0.0);   // RawSlope: 0 = нейтрально (для EA)

   // --- Начало отрисовки (пропуск разогрева JMA + ATR) ---
   int drawBegin = MathMax(32, ATR_Period + 1);
   SetIndexDrawBegin(0, drawBegin);
   SetIndexDrawBegin(1, drawBegin);
   SetIndexDrawBegin(2, drawBegin);

   // --- Подписи буферов (видны в DataWindow и при выборе в iCustom) ---
   SetIndexLabel(0, "NormSlope Up");
   SetIndexLabel(1, "NormSlope Down");
   SetIndexLabel(2, "JMA Value");
   SetIndexLabel(3, "NormSlope");
   SetIndexLabel(4, "RawSlope");
   SetIndexLabel(5, NULL);   // Скрыть в DataWindow
   SetIndexLabel(6, NULL);
   SetIndexLabel(7, NULL);

   // --- Короткое имя индикатора ---
   IndicatorShortName("JMASlope(" + IntegerToString(JMA_Length) + ","
                      + IntegerToString(JMA_Phase) + ",ATR"
                      + IntegerToString(ATR_Period) + ")");

   // --- Горизонтальные уровни ---
   SetLevelValue(0, 0.0);       // Нулевая линия
   SetLevelStyle(STYLE_DOT, 1, clrGray);

   // --- Предвычисление констант JMA ---
   PrecomputeJMAConstants();

   // --- Сброс состояния алгоритма ---
   ResetJMAState();

   Print("[JMASlope v2.0] Инициализация: Length=", JMA_Length,
         " Phase=", JMA_Phase, " ATR=", ATR_Period,
         " Multiplier=", NormMultiplier);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 5: ОСНОВНОЙ РАСЧЁТ (OnCalculate)                            |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // --- Проверка минимального количества баров ---
   int minBars = MathMax(33, ATR_Period + 2);
   if(rates_total < minBars) return(0);

   // --- Определение диапазона расчёта ---
   int limit;

   if(prev_calculated == 0)
   {
      // Полный пересчёт: сброс всего состояния JMA
      ResetJMAState();
      limit = rates_total - 1;
   }
   else
   {
      // Инкрементальный: только новые закрытые бары
      limit = rates_total - prev_calculated;

      // Anti-repaint: если новых закрытых баров нет — выход
      if(limit <= 0) return(rates_total);
   }

   // === ОСНОВНОЙ ЦИКЛ: от старых к новым, строго до i=1 ===
   // JMA — последовательный алгоритм с накоплением состояния.
   // Каждый бар обрабатывается ровно один раз (anti-repaint).
   for(int shift = limit; shift >= 1; shift--)
   {
      // --- Получение цены по выбранному типу ---
      double series = GetAppliedPrice(AppliedPrice, open, high, low, close, shift);

      // ================================================================
      //  НАЧАЛО АЛГОРИТМА JMA (Jurik Moving Average)
      //  Адаптивная скользящая средняя с медианным фильтром волатильности.
      //  Оригинал: Jurik Research, реализация TrendLaboratory 2005.
      //  Математика сохранена без изменений — рефакторинг только структуры.
      // ================================================================

      // --- ФАЗА 1: Накопление данных разогрева (первые 30+ баров) ---
      if(g_warmupCount < 61)
      {
         g_warmupCount++;
         g_warmupData[g_warmupCount] = series;
      }

      // Недостаточно данных — пишем EMPTY_VALUE
      if(g_warmupCount <= 30)
      {
         JMAValueBuf[shift]   = EMPTY_VALUE;
         RawSlopeBuf[shift]   = 0.0;
         NormSlopeBuf[shift]  = 0.0;
         NormSlopeUpBuf[shift] = EMPTY_VALUE;
         NormSlopeDnBuf[shift] = EMPTY_VALUE;
         continue;  // Переход к следующему бару
      }

      // --- ФАЗА 2: Инициализация (однократно после разогрева) ---
      int highLimit;
      if(g_isFirstCalc)
      {
         g_isFirstCalc = false;

         // Проверяем: есть ли различия в ценах разогрева
         int diffFlag = 0;
         for(int k = 1; k <= 29; k++)
         {
            if(g_warmupData[k + 1] != g_warmupData[k])
            {
               diffFlag = 1;
               break;   // Оптимизация: ранний выход
            }
         }
         highLimit = diffFlag * 30;

         // Инициализация адаптивных трекеров
         if(highLimit == 0)
            g_trackLow = series;
         else
            g_trackLow = g_warmupData[1];

         g_trackHigh = g_trackLow;
         if(highLimit > 29) highLimit = 29;
      }
      else
      {
         highLimit = 0;  // Обычный режим: обрабатываем только текущий бар
      }

      // --- ФАЗА 3: Главный цикл JMA ---
      // При инициализации: обрабатывает пакет данных разогрева (highLimit итераций).
      // В обычном режиме: одна итерация (highLimit=0, jmaI от 0 до 0).
      double dValue = 0.0;             // Адаптивный параметр сглаживания (используется после цикла)
      double jmaTempValue = series;    // Временное значение JMA

      for(int jmaI = highLimit; jmaI >= 0; jmaI--)
      {
         // Выбор входного значения: из буфера разогрева или текущая цена
         double sValue;
         if(jmaI == 0)
            sValue = series;
         else
            sValue = g_warmupData[31 - jmaI];

         // --- Расчёт волатильности (максимальное отклонение от трекеров) ---
         double absValue;
         if(MathAbs(sValue - g_trackHigh) > MathAbs(sValue - g_trackLow))
            absValue = MathAbs(sValue - g_trackHigh);
         else
            absValue = MathAbs(sValue - g_trackLow);

         dValue = absValue + 1.0e-10;  // Защита от нуля

         // --- Обновление кольцевых буферов волатильности ---
         if(g_volHistIdx <= 1) g_volHistIdx = 127; else g_volHistIdx--;
         if(g_recentVolIdx <= 1) g_recentVolIdx = 10; else g_recentVolIdx--;
         if(g_volSampleCount < 128) g_volSampleCount++;

         // Скользящая сумма недавней волатильности (окно = 10)
         g_volSum += (dValue - g_recentVol[g_recentVolIdx]);
         g_recentVol[g_recentVolIdx] = dValue;

         // Средняя недавняя волатильность
         double avgVol;
         if(g_volSampleCount > 10)
            avgVol = g_volSum / 10.0;
         else
            avgVol = g_volSum / (double)g_volSampleCount;

         // --- Обновление отсортированного массива (медианный фильтр) ---
         int searchOldPos, searchNewPos, searchStep;

         if(g_volSampleCount > 127)
         {
            // === Режим замены: массив полностью заполнен ===
            // Удаляем старое значение, вставляем новое
            dValue = g_volHistory[g_volHistIdx];
            g_volHistory[g_volHistIdx] = avgVol;

            // Бинарный поиск позиции старого значения в отсортированном массиве
            searchStep = 64;
            searchOldPos = searchStep;
            while(searchStep > 1)
            {
               if(g_sortedList[searchOldPos] < dValue)
               {
                  searchStep = (int)(searchStep / 2.0);
                  searchOldPos += searchStep;
               }
               else if(g_sortedList[searchOldPos] <= dValue)
               {
                  searchStep = 1;  // Найдено точное совпадение
               }
               else
               {
                  searchStep = (int)(searchStep / 2.0);
                  searchOldPos -= searchStep;
               }
            }
         }
         else
         {
            // === Режим заполнения: массив ещё не полон ===
            g_volHistory[g_volHistIdx] = avgVol;

            if((g_listLowBound + g_listHighBound) > 127)
            {
               g_listHighBound--;
               searchOldPos = g_listHighBound;
            }
            else
            {
               g_listLowBound++;
               searchOldPos = g_listLowBound;
            }

            // Обновление границ медианного диапазона
            if(g_listLowBound > 96) g_medianHigh = 96; else g_medianHigh = g_listLowBound;
            if(g_listHighBound < 32) g_medianLow = 32; else g_medianLow = g_listHighBound;
         }

         // --- Бинарный поиск позиции нового значения ---
         searchStep = 64;
         searchNewPos = searchStep;
         while(searchStep > 1)
         {
            if(g_sortedList[searchNewPos] >= avgVol)
            {
               if(g_sortedList[searchNewPos - 1] <= avgVol)
               {
                  searchStep = 1;  // Позиция найдена
               }
               else
               {
                  searchStep = (int)(searchStep / 2.0);
                  searchNewPos -= searchStep;
               }
            }
            else
            {
               searchStep = (int)(searchStep / 2.0);
               searchNewPos += searchStep;
            }
            // Обработка крайнего случая: значение больше всех в массиве
            if((searchNewPos == 127) && (avgVol > g_sortedList[127]))
               searchNewPos = 128;
         }

         // --- Инкрементальное обновление суммы медианного диапазона ---
         if(g_volSampleCount > 127)
         {
            // Добавление нового значения в медианную сумму
            if(searchOldPos >= searchNewPos)
            {
               if(((g_medianHigh + 1) > searchNewPos) && ((g_medianLow - 1) < searchNewPos))
                  g_medianSum += avgVol;
               else if((g_medianLow > searchNewPos) && ((g_medianLow - 1) < searchOldPos))
                  g_medianSum += g_sortedList[g_medianLow - 1];
            }
            else if(g_medianLow >= searchNewPos)
            {
               if(((g_medianHigh + 1) < searchNewPos) && ((g_medianHigh + 1) > searchOldPos))
                  g_medianSum += g_sortedList[g_medianHigh + 1];
            }
            else if((g_medianHigh + 2) > searchNewPos)
               g_medianSum += avgVol;
            else if(((g_medianHigh + 1) < searchNewPos) && ((g_medianHigh + 1) > searchOldPos))
               g_medianSum += g_sortedList[g_medianHigh + 1];

            // Вычитание старого значения из медианной суммы
            if(searchOldPos > searchNewPos)
            {
               if(((g_medianLow - 1) < searchOldPos) && ((g_medianHigh + 1) > searchOldPos))
                  g_medianSum -= g_sortedList[searchOldPos];
               else if((g_medianHigh < searchOldPos) && ((g_medianHigh + 1) > searchNewPos))
                  g_medianSum -= g_sortedList[g_medianHigh];
            }
            else
            {
               if(((g_medianHigh + 1) > searchOldPos) && ((g_medianLow - 1) < searchOldPos))
                  g_medianSum -= g_sortedList[searchOldPos];
               else if((g_medianLow > searchOldPos) && (g_medianLow < searchNewPos))
                  g_medianSum -= g_sortedList[g_medianLow];
            }
         }

         // --- Сдвиг элементов и вставка нового значения ---
         if(searchOldPos <= searchNewPos)
         {
            if(searchOldPos >= searchNewPos)
            {
               g_sortedList[searchNewPos] = avgVol;
            }
            else
            {
               for(int j = searchOldPos + 1; j <= (searchNewPos - 1); j++)
                  g_sortedList[j - 1] = g_sortedList[j];
               g_sortedList[searchNewPos - 1] = avgVol;
            }
         }
         else
         {
            for(int j = searchOldPos - 1; j >= searchNewPos; j--)
               g_sortedList[j + 1] = g_sortedList[j];
            g_sortedList[searchNewPos] = avgVol;
         }

         // --- Полный пересчёт медианной суммы (фаза заполнения) ---
         if(g_volSampleCount <= 127)
         {
            g_medianSum = 0;
            for(int j = g_medianLow; j <= g_medianHigh; j++)
               g_medianSum += g_sortedList[j];
         }

         // --- Адаптивное сглаживание ---
         if(g_mainPhaseCount + 1 > 31)
            g_mainPhaseCount = 31;
         else
            g_mainPhaseCount++;

         double sqrtDivider = g_sqrtParam / (g_sqrtParam + 1.0);

         if(g_mainPhaseCount <= 30)
         {
            // === Фаза разгона: простое адаптивное отслеживание ===
            if(sValue - g_trackHigh > 0)
               g_trackHigh = sValue;
            else
               g_trackHigh = sValue - (sValue - g_trackHigh) * sqrtDivider;

            if(sValue - g_trackLow < 0)
               g_trackLow = sValue;
            else
               g_trackLow = sValue - (sValue - g_trackLow) * sqrtDivider;

            jmaTempValue = series;

            if(g_mainPhaseCount == 30)
            {
               // Момент перехода в основную фазу: вычисление начальных значений
               fC0Buf[shift] = series;

               int intPart;
               if(MathCeil(g_sqrtParam) >= 1)
                  intPart = (int)MathCeil(g_sqrtParam);
               else
                  intPart = 1;
               int leftInt = IntPortion(intPart);

               if(MathFloor(g_sqrtParam) >= 1)
                  intPart = (int)MathFloor(g_sqrtParam);
               else
                  intPart = 1;
               int rightPart = IntPortion(intPart);

               double interpWeight;
               if(leftInt == rightPart)
                  interpWeight = 1.0;
               else
                  interpWeight = (g_sqrtParam - rightPart) / (double)(leftInt - rightPart);

               int upShift = (rightPart <= 29) ? rightPart : 29;
               int dnShift = (leftInt <= 29) ? leftInt : 29;

               fA8Buf[shift] = (series - g_warmupData[g_warmupCount - upShift]) * (1.0 - interpWeight) / (double)rightPart
                             + (series - g_warmupData[g_warmupCount - dnShift]) * interpWeight / (double)leftInt;
            }
         }
         else
         {
            // === Основная фаза: адаптивный JMA с медианным фильтром ===
            double powerValue;
            double medianAvg = g_medianSum / (double)(g_medianHigh - g_medianLow + 1);

            if(0.5 <= g_logParam - 2.0)
               powerValue = g_logParam - 2.0;
            else
               powerValue = 0.5;

            if(g_logParam >= MathPow(absValue / medianAvg, powerValue))
               dValue = MathPow(absValue / medianAvg, powerValue);
            else
               dValue = g_logParam;

            if(dValue < 1.0) dValue = 1.0;

            powerValue = MathPow(sqrtDivider, MathSqrt(dValue));

            if(sValue - g_trackHigh > 0)
               g_trackHigh = sValue;
            else
               g_trackHigh = sValue - (sValue - g_trackHigh) * powerValue;

            if(sValue - g_trackLow < 0)
               g_trackLow = sValue;
            else
               g_trackLow = sValue - (sValue - g_trackLow) * powerValue;
         }
      }
      // === КОНЕЦ ГЛАВНОГО ЦИКЛА JMA ===

      // --- ФАЗА 4: Вычисление итогового значения JMA ---
      if(g_mainPhaseCount > 30)
      {
         // Основной режим: рекурсивный фильтр с адаптивным параметром
         double prevJMA = JMAValueBuf[shift + 1];
         if(prevJMA == EMPTY_VALUE) prevJMA = series;  // Защита для первого бара основной фазы

         double prevC0 = fC0Buf[shift + 1];
         double prevA8 = fA8Buf[shift + 1];
         double prevC8 = fC8Buf[shift + 1];

         double powerValue  = MathPow(g_lengthDivider, dValue);
         double squareValue = MathPow(powerValue, 2.0);

         // Первый фильтр: экспоненциальное сглаживание цены
         fC0Buf[shift] = (1.0 - powerValue) * series + powerValue * prevC0;

         // Второй фильтр: отклонение цены от первого фильтра
         fC8Buf[shift] = (series - fC0Buf[shift]) * (1.0 - g_lengthDivider) + g_lengthDivider * prevC8;

         // Адаптивный компонент: комбинация фильтров с фазовой коррекцией
         fA8Buf[shift] = (g_phaseParam * fC8Buf[shift] + fC0Buf[shift] - prevJMA)
                       * (powerValue * (-2.0) + squareValue + 1.0)
                       + squareValue * prevA8;

         jmaTempValue = prevJMA + fA8Buf[shift];
      }

      // Запись значения JMA
      JMAValueBuf[shift] = jmaTempValue;

      // ================================================================
      //  КОНЕЦ АЛГОРИТМА JMA
      // ================================================================

      // --- РАСЧЁТ НАКЛОНА (SLOPE) И ATR НОРМАЛИЗАЦИЯ ---
      if(JMAValueBuf[shift] == EMPTY_VALUE || JMAValueBuf[shift + 1] == EMPTY_VALUE)
      {
         // Данные ещё не готовы
         RawSlopeBuf[shift]   = 0.0;
         NormSlopeBuf[shift]  = 0.0;
         NormSlopeUpBuf[shift] = EMPTY_VALUE;
         NormSlopeDnBuf[shift] = EMPTY_VALUE;
         continue;
      }

      // Сырой наклон: разница JMA между текущим и предыдущим закрытым баром
      double rawSlope = JMAValueBuf[shift] - JMAValueBuf[shift + 1];
      RawSlopeBuf[shift] = rawSlope;

      // ATR нормализация: slope / ATR × множитель
      double atr = iATR(NULL, 0, ATR_Period, shift);

      if(atr > _Point * 0.1)  // Защита от деления на ноль / микро-ATR
      {
         double normSlope = (rawSlope / atr) * NormMultiplier;
         NormSlopeBuf[shift] = normSlope;

         // Распределение по гистограмме: очистка противоположного буфера
         if(normSlope > 0.0)
         {
            NormSlopeUpBuf[shift] = normSlope;
            NormSlopeDnBuf[shift] = EMPTY_VALUE;  // Очистка!
         }
         else if(normSlope < 0.0)
         {
            NormSlopeUpBuf[shift] = EMPTY_VALUE;   // Очистка!
            NormSlopeDnBuf[shift] = normSlope;
         }
         else
         {
            NormSlopeUpBuf[shift] = EMPTY_VALUE;
            NormSlopeDnBuf[shift] = EMPTY_VALUE;
         }
      }
      else
      {
         // ATR слишком мал (flat market / выходные)
         NormSlopeBuf[shift]   = 0.0;
         NormSlopeUpBuf[shift] = EMPTY_VALUE;
         NormSlopeDnBuf[shift] = EMPTY_VALUE;
      }
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                  |
//+------------------------------------------------------------------+

//--- Предвычисление констант JMA (один раз при инициализации) -------
void PrecomputeJMAConstants()
{
   // Параметр длины: (Length - 1) / 2
   double lengthParam;
   if(JMA_Length < 2)
      lengthParam = 0.0000000001;
   else
      lengthParam = (JMA_Length - 1) / 2.0;

   // Параметр фазы: преобразование [-100..+100] → [0.5..2.5]
   if(JMA_Phase < -100)
      g_phaseParam = 0.5;
   else if(JMA_Phase > 100)
      g_phaseParam = 2.5;
   else
      g_phaseParam = JMA_Phase / 100.0 + 1.5;

   // Логарифмический параметр: log2(sqrt(lengthParam)) + 2
   g_logParam = MathLog(MathSqrt(lengthParam)) / MathLog(2.0);

   if(g_logParam + 2.0 < 0.0)
      g_logParam = 0.0;
   else
      g_logParam = g_logParam + 2.0;

   // Квадратный корень × логарифм
   g_sqrtParam = MathSqrt(lengthParam) * g_logParam;

   // Делитель длины: используется для экспоненциального сглаживания
   double adjustedLen = lengthParam * 0.9;
   g_lengthDivider = adjustedLen / (adjustedLen + 2.0);
}

//--- Полный сброс состояния алгоритма JMA ---------------------------
void ResetJMAState()
{
   // Инициализация отсортированного массива: нижняя половина = -1M, верхняя = +1M
   for(int i = 0; i <= 63; i++)
      g_sortedList[i] = -1000000.0;
   for(int i = 64; i <= 127; i++)
      g_sortedList[i] = 1000000.0;

   // Очистка кольцевых буферов
   ArrayInitialize(g_volHistory, 0.0);
   ArrayInitialize(g_recentVol, 0.0);
   ArrayInitialize(g_warmupData, 0.0);

   // Сброс скалярных переменных
   g_isFirstCalc    = true;
   g_warmupCount    = 0;
   g_mainPhaseCount = 0;
   g_volHistIdx     = 0;
   g_recentVolIdx   = 0;
   g_volSampleCount = 0;
   g_listLowBound   = 63;   // Начальные границы отсортированного массива
   g_listHighBound  = 64;
   g_medianHigh     = 0;
   g_medianLow      = 0;
   g_volSum         = 0.0;
   g_medianSum      = 0.0;
   g_trackHigh      = 0.0;
   g_trackLow       = 0.0;
}

//--- Получение цены по типу Applied Price ---------------------------
double GetAppliedPrice(ENUM_APPLIED_PRICE priceType,
                       const double &open[],
                       const double &high[],
                       const double &low[],
                       const double &close[],
                       int idx)
{
   switch(priceType)
   {
      case PRICE_OPEN:     return(open[idx]);
      case PRICE_HIGH:     return(high[idx]);
      case PRICE_LOW:      return(low[idx]);
      case PRICE_MEDIAN:   return((high[idx] + low[idx]) / 2.0);
      case PRICE_TYPICAL:  return((high[idx] + low[idx] + close[idx]) / 3.0);
      case PRICE_WEIGHTED: return((high[idx] + low[idx] + close[idx] + close[idx]) / 4.0);
      default:             return(close[idx]);  // PRICE_CLOSE
   }
}

//--- Целая часть числа (floor для положительных, ceil для отрицательных)
int IntPortion(double param)
{
   if(param > 0.0) return((int)MathFloor(param));
   if(param < 0.0) return((int)MathCeil(param));
   return(0);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ДЕИНИЦИАЛИЗАЦИЯ (OnDeinit)                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Очистка не требуется — буферы управляются терминалом.
   // Логирование причины завершения для отладки.
   if(reason != REASON_CHARTCHANGE && reason != REASON_PARAMETERS)
   {
      Print("[JMASlope v2.0] Деинициализация, причина: ", reason);
   }
}

//+------------------------------------------------------------------+
//| БЛОК 8: ДОКУМЕНТАЦИЯ ДЛЯ EA (iCustom)                           |
//+------------------------------------------------------------------+
//
// ИСПОЛЬЗОВАНИЕ В ЭКСПЕРТЕ:
//
// double normSlope = iCustom(Symbol(), 0, "JMASlope_v2_0",
//                            14,            // JMA_Length
//                            0,             // JMA_Phase
//                            14,            // ATR_Period
//                            1000.0,        // NormMultiplier
//                            PRICE_CLOSE,   // AppliedPrice
//                            3,             // Буфер: NormSlope (основной!)
//                            1);            // Бар: i=1 (закрытый, anti-repaint)
//
// double jmaValue = iCustom(Symbol(), 0, "JMASlope_v2_0",
//                           14, 0, 14, 1000.0, PRICE_CLOSE,
//                           2,             // Буфер: JMA Value
//                           1);
//
// double rawSlope = iCustom(Symbol(), 0, "JMASlope_v2_0",
//                           14, 0, 14, 1000.0, PRICE_CLOSE,
//                           4,             // Буфер: RawSlope
//                           1);
//
// ИНТЕРПРЕТАЦИЯ NormSlope:
//   > 0   : бычий наклон (JMA растёт)
//   < 0   : медвежий наклон (JMA падает)
//   > 200 : сильный бычий импульс
//   < -200: сильный медвежий импульс
//   ≈ 0   : флэт / разворот
//
// Значения сопоставимы между инструментами:
//   NormSlope 150 на GBPUSD ≈ NormSlope 150 на USDJPY
//
//+------------------------------------------------------------------+
