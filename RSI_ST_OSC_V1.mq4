//+------------------------------------------------------------------+
//|                                                RSI_ST_OSC_V1.mq4 |
//|                        Осциллятор на основе RSI и Stochastic     |
//|                           Copyright © 2026, Ruslan Kuchma  |
//+------------------------------------------------------------------+
//| ОПИСАНИЕ:                                                         |
//|   Комбинированный осциллятор с условиями пересечения уровня 50   |
//|   - Гистограммы выше/ниже нуля (DeepSkyBlue/Magenta)            |
//|   - ATR-нормализация высоты (как Market_Pulse_Squeeze_v3)       |
//|   - Сохранение предыдущего сигнала при отсутствии нового         |
//|   - БЕЗ РЕПЕЙНТА (расчет только закрытых баров)                  |
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTIES И НАСТРОЙКИ ВИЗУАЛИЗАЦИИ                      |
//+------------------------------------------------------------------+
#property indicator_separate_window      // Индикатор в отдельном окне
#property indicator_buffers 3            // 3 буфера (2 видимых + 1 служебный)
#property indicator_plots   2            // 2 видимых гистограммы

// Гистограмма BUY (DeepSkyBlue, выше нуля)
#property indicator_label1  "BUY Signal"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrDeepSkyBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3

// Гистограмма SELL (Magenta, ниже нуля)
#property indicator_label2  "SELL Signal"
#property indicator_type2   DRAW_HISTOGRAM
#property indicator_color2  clrMagenta
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

// Нулевая линия (разделитель)
#property indicator_level1  0.0
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT
#property indicator_levelwidth 1

//+------------------------------------------------------------------+
//| БЛОК 2: ВНЕШНИЕ ПАРАМЕТРЫ                                        |
//+------------------------------------------------------------------+
input string S1 = "=== RSI ПАРАМЕТРЫ ===";           // ═══════════════
input int    RSI_Period = 14;                         // RSI период
input ENUM_APPLIED_PRICE RSI_AppliedPrice = PRICE_CLOSE; // RSI цена

input string S2 = "=== STOCHASTIC ПАРАМЕТРЫ ===";    // ═══════════════
input int    Stoch_K_Period = 14;                     // Stochastic %K период
input int    Stoch_D_Period = 3;                     // Stochastic %D период
input int    Stoch_Slowing = 3;                      // Stochastic замедление
input ENUM_MA_METHOD Stoch_MA_Method = MODE_SMA;     // Stochastic метод MA
input ENUM_STO_PRICE Stoch_PriceField = STO_CLOSECLOSE; // Stochastic поле цены

input string S3 = "=== ATR НОРМАЛИЗАЦИЯ ===";        // ═══════════════
input int    ATR_Period = 14;                        // ATR период для нормализации
input double ATR_Multiplier = 1.0;                   // Множитель высоты гистограмм

input string S4 = "=== УРОВЕНЬ ПЕРЕСЕЧЕНИЯ ===";     // ═══════════════
input double CrossLevel = 50.0;                      // Уровень пересечения (обычно 50)

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                    |
//+------------------------------------------------------------------+
// Минимальное количество баров для расчета
int g_MinBarsRequired;

//+------------------------------------------------------------------+
//| БЛОК 4: ИНДИКАТОРНЫЕ БУФЕРЫ                                      |
//+------------------------------------------------------------------+
// Видимые буферы (гистограммы)
double BuySignalBuffer[];      // Буфер 0: BUY сигнал (DeepSkyBlue, выше нуля)
double SellSignalBuffer[];     // Буфер 1: SELL сигнал (Magenta, ниже нуля)

// Служебный буфер для EA (невидимый)
double DirectionBuffer[];      // Буфер 2: Направление (+1=BUY, -1=SELL, 0=нейтрал)

//+------------------------------------------------------------------+
//| БЛОК 5: ИНИЦИАЛИЗАЦИЯ (OnInit)                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Проверка корректности входных параметров
   if(RSI_Period < 2 || RSI_Period > 100)
   {
      Print("ОШИБКА: RSI_Period должен быть в диапазоне 2-100. Установлено: ", RSI_Period);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(Stoch_K_Period < 1 || Stoch_K_Period > 100)
   {
      Print("ОШИБКА: Stoch_K_Period должен быть в диапазоне 1-100. Установлено: ", Stoch_K_Period);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(Stoch_D_Period < 1 || Stoch_D_Period > 100)
   {
      Print("ОШИБКА: Stoch_D_Period должен быть в диапазоне 1-100. Установлено: ", Stoch_D_Period);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(Stoch_Slowing < 1 || Stoch_Slowing > 100)
   {
      Print("ОШИБКА: Stoch_Slowing должен быть в диапазоне 1-100. Установлено: ", Stoch_Slowing);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(ATR_Period < 5 || ATR_Period > 100)
   {
      Print("ОШИБКА: ATR_Period должен быть в диапазоне 5-100. Установлено: ", ATR_Period);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   //--- Расчет минимального количества баров
   g_MinBarsRequired = MathMax(RSI_Period, Stoch_K_Period + Stoch_D_Period + Stoch_Slowing) + ATR_Period + 2;
   
   //--- Привязка буферов к массивам
   SetIndexBuffer(0, BuySignalBuffer);
   SetIndexBuffer(1, SellSignalBuffer);
   SetIndexBuffer(2, DirectionBuffer);      // Невидимый буфер для EA
   
   //--- Настройка стилей отображения
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrDeepSkyBlue);
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrMagenta);
   SetIndexStyle(2, DRAW_NONE);              // Невидимый буфер
   
   //--- Установка EMPTY_VALUE для корректной обработки пропущенных значений
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, 0.0);               // Для буфера направления 0 = нейтрал
   
   //--- Метки для Data Window
   SetIndexLabel(0, "BUY Signal");
   SetIndexLabel(1, "SELL Signal");
   SetIndexLabel(2, "Direction");
   
   //--- Название индикатора в подокне
   string indicatorName = StringFormat("RSI_ST_OSC (RSI:%d | Stoch:%d,%d,%d | ATR:%d)",
                                        RSI_Period,
                                        Stoch_K_Period, Stoch_D_Period, Stoch_Slowing,
                                        ATR_Period);
   IndicatorShortName(indicatorName);
   
   //--- Точность отображения (2 знака после запятой для нормализованных значений)
   IndicatorDigits(2);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ОСНОВНОЙ РАСЧЕТ (OnCalculate)                           |
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
   //--- Проверка достаточности данных
   if(rates_total < g_MinBarsRequired)
   {
      Print("Недостаточно баров для расчёта. Требуется минимум: ", g_MinBarsRequired, 
            ", доступно: ", rates_total);
      return(0);
   }
   
   //--- Определение стартовой позиции для расчёта (оптимизация через prev_calculated)
   int startPos;
   
   if(prev_calculated == 0)
   {
      // Первый запуск индикатора — рассчитываем все бары
      startPos = rates_total - g_MinBarsRequired;
      
      // Инициализация всех буферов значением EMPTY_VALUE / 0
      ArrayInitialize(BuySignalBuffer, EMPTY_VALUE);
      ArrayInitialize(SellSignalBuffer, EMPTY_VALUE);
      ArrayInitialize(DirectionBuffer, 0.0);
   }
   else
   {
      // Пересчитываем только новые бары
      startPos = rates_total - prev_calculated;
   }
   
   //--- Основной цикл расчёта (от старых баров к новым)
   // КРИТИЧНО: Цикл идёт до i >= 1 (НЕ до i >= 0!) для избежания репейнта
   for(int shift = startPos; shift >= 1; shift--)  // ← ВАЖНО: shift >= 1
   {
      //--- ШАБЛОН 1: Получение значений RSI и Stochastic на ТЕКУЩЕМ баре (i)
      double rsi_current = iRSI(NULL, 0, RSI_Period, RSI_AppliedPrice, shift);
      double stoch_current = iStochastic(NULL, 0, Stoch_K_Period, Stoch_D_Period, Stoch_Slowing,
                                          Stoch_MA_Method, Stoch_PriceField, MODE_MAIN, shift);
      
      //--- ШАБЛОН 2: Получение значений RSI и Stochastic на ПРЕДЫДУЩЕМ баре (i+1)
      double rsi_prev = iRSI(NULL, 0, RSI_Period, RSI_AppliedPrice, shift + 1);
      double stoch_prev = iStochastic(NULL, 0, Stoch_K_Period, Stoch_D_Period, Stoch_Slowing,
                                       Stoch_MA_Method, Stoch_PriceField, MODE_MAIN, shift + 1);
      
      //--- ЗАЩИТА: Проверка корректности значений (на случай ошибок индикаторов)
      if(rsi_current == EMPTY_VALUE || stoch_current == EMPTY_VALUE ||
         rsi_prev == EMPTY_VALUE || stoch_prev == EMPTY_VALUE)
      {
         BuySignalBuffer[shift] = EMPTY_VALUE;
         SellSignalBuffer[shift] = EMPTY_VALUE;
         DirectionBuffer[shift] = 0.0;
         continue;
      }
      
      //--- ШАБЛОН 3: Определение пересечений уровня CrossLevel
      // Stochastic пересекает уровень 50
      bool stoch_cross_up = (stoch_prev < CrossLevel && stoch_current >= CrossLevel);
      bool stoch_cross_down = (stoch_prev > CrossLevel && stoch_current <= CrossLevel);
      
      // RSI пересекает уровень 50
      bool rsi_cross_up = (rsi_prev < CrossLevel && rsi_current >= CrossLevel);
      bool rsi_cross_down = (rsi_prev > CrossLevel && rsi_current <= CrossLevel);
      
      // Текущее положение относительно уровня 50
      bool rsi_above = (rsi_current > CrossLevel);
      bool rsi_below = (rsi_current < CrossLevel);
      bool stoch_above = (stoch_current > CrossLevel);
      bool stoch_below = (stoch_current < CrossLevel);
      
      //--- ШАБЛОН 4: Логика формирования сигналов
      bool buy_signal = false;
      bool sell_signal = false;
      
      // BUY сигнал:
      // (Stochastic пересек 50 снизу вверх) И (RSI находится выше 50)
      // ИЛИ
      // (RSI пересек 50 снизу вверх) И (Stochastic находится выше 50)
      if((stoch_cross_up && rsi_above) || (rsi_cross_up && stoch_above))
      {
         buy_signal = true;
      }
      
      // SELL сигнал:
      // (Stochastic пересек 50 сверху вниз) И (RSI находится ниже 50)
      // ИЛИ
      // (RSI пересек 50 сверху вниз) И (Stochastic находится ниже 50)
      if((stoch_cross_down && rsi_below) || (rsi_cross_down && stoch_below))
      {
         sell_signal = true;
      }
      
      //--- ШАБЛОН 5: Определение текущего направления
      int current_direction = 0;
      
      if(buy_signal)
      {
         current_direction = 1;   // BUY
      }
      else if(sell_signal)
      {
         current_direction = -1;  // SELL
      }
      else
      {
         // Если нет нового сигнала - сохраняем предыдущее направление
         if(shift + 1 < rates_total)
         {
            current_direction = (int)DirectionBuffer[shift + 1];
         }
         else
         {
            current_direction = 0;  // Нейтрал (первый бар)
         }
      }
      
      //--- ШАБЛОН 6: ATR-нормализация высоты гистограмм
      // Получаем ATR для динамической высоты (как в Market_Pulse_Squeeze_v3)
      double atr = iATR(NULL, 0, ATR_Period, shift);
      
      // Защита от деления на ноль
      if(atr < _Point * 10)
      {
         atr = _Point * 10;  // Минимальное значение ATR
      }
      
      // Базовая высота гистограммы (нормализованная через ATR)
      // Используем константу для масштабирования
      double bar_height = ATR_Multiplier * (atr / _Point);
      
      //--- ШАБЛОН 7: Заполнение буферов в зависимости от направления
      if(current_direction == 1)
      {
         // BUY сигнал: гистограмма DeepSkyBlue выше нуля
         BuySignalBuffer[shift] = bar_height;
         SellSignalBuffer[shift] = EMPTY_VALUE;
         DirectionBuffer[shift] = 1.0;
      }
      else if(current_direction == -1)
      {
         // SELL сигнал: гистограмма Magenta ниже нуля
         BuySignalBuffer[shift] = EMPTY_VALUE;
         SellSignalBuffer[shift] = -bar_height;
         DirectionBuffer[shift] = -1.0;
      }
      else
      {
         // Нейтрал: нет гистограмм
         BuySignalBuffer[shift] = EMPTY_VALUE;
         SellSignalBuffer[shift] = EMPTY_VALUE;
         DirectionBuffer[shift] = 0.0;
      }
   }
   
   //--- КРИТИЧНО: Обнуление текущего бара (i=0) для избежания репейнта
   BuySignalBuffer[0] = EMPTY_VALUE;
   SellSignalBuffer[0] = EMPTY_VALUE;
   DirectionBuffer[0] = 0.0;
   
   //--- Возвращаем количество обработанных баров
   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ДЕИНИЦИАЛИЗАЦИЯ (OnDeinit)                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Очистка объектов (если были созданы)
   // В данном индикаторе дополнительная очистка не требуется
}

//+------------------------------------------------------------------+
//| ПРИМЕЧАНИЯ ДЛЯ ИСПОЛЬЗОВАНИЯ В EA:                               |
//+------------------------------------------------------------------+
/*
   Буфер 2 (DirectionBuffer) доступен через iCustom для Expert Advisor:
   
   double direction = iCustom(Symbol(), 0, "RSI_ST_OSC_V1", 
                               RSI_Period, RSI_AppliedPrice,
                               Stoch_K_Period, Stoch_D_Period, Stoch_Slowing,
                               Stoch_MA_Method, Stoch_PriceField,
                               ATR_Period, ATR_Multiplier,
                               CrossLevel,
                               2,    // ← Буфер 2 (DirectionBuffer)
                               1);   // ← shift=1 (закрытый бар)
   
   Интерпретация:
   - direction == 1.0  → BUY сигнал (можно открывать длинную позицию)
   - direction == -1.0 → SELL сигнал (можно открывать короткую позицию)
   - direction == 0.0  → Нейтрал (нет сигнала)
   
   ВАЖНО: Всегда используйте shift=1 (закрытый бар) для избежания репейнта!
*/
//+------------------------------------------------------------------+
