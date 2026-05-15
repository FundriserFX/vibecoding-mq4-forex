//+------------------------------------------------------------------+
//|                                          osc_KagiFlow_v1_0.mq4   |
//|                       Kagi Flow Oscillator v1.0                  |
//|                       Copyright © 2026, Ruslan Kuchma            |
//|                       https://t.me/RuslanKuchma                  |
//+------------------------------------------------------------------+
//| ОПИСАНИЕ:                                                         |
//|   Универсальный осциллятор на базе классической формулы Kagi.    |
//|   - ATR-нормализация порога разворота (универсально для любых ТФ)|
//|   - tanh-bounded output в [-1, +1]                               |
//|   - Опциональный Yang/Yin режим (классика Steve Nison)           |
//|   - Reversal Proximity — опережающий сигнал разворота для EA     |
//|   - БЕЗ РЕПЕЙНТА: расчёт только закрытых баров (shift >= 1)      |
//|                                                                   |
//| КОНТРАКТ ИНТЕГРАЦИИ В EA (iCustom):                              |
//|   Буфер 0: Bull Histogram (видимый)                              |
//|   Буфер 1: Bear Histogram (видимый)                              |
//|   Буфер 2: Direction      (для EA: -2/-1/0/+1/+2)                |
//|   Буфер 3: Strength       (для EA: |Output| в [0, 1])            |
//|   Буфер 4: Proximity      (для EA: 0...1 опережающий разворот)   |
//|   Буфер 5: BarsInTrend    (для EA: счётчик баров в тренде)       |
//+------------------------------------------------------------------+
#property copyright "Copyright © 2026, Ruslan Kuchma"
#property link      "https://t.me/RuslanKuchma"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTIES И НАСТРОЙКИ ВИЗУАЛИЗАЦИИ                      |
//+------------------------------------------------------------------+
#property indicator_separate_window      // Индикатор в отдельном окне
#property indicator_buffers 10           // 6 контрактных + 4 служебных буфера
#property indicator_plots   2            // 2 видимые гистограммы

#property indicator_minimum -1.1         // Минимум шкалы (с запасом)
#property indicator_maximum  1.1         // Максимум шкалы (с запасом)

// Уровни ±0.7 и 0 (зоны перекупленности/перепроданности)
#property indicator_level1   0.7
#property indicator_level2   0.0
#property indicator_level3  -0.7
#property indicator_levelcolor clrDarkGray
#property indicator_levelstyle STYLE_DOT
#property indicator_levelwidth 1

// Буфер 0: Бычья гистограмма (Output, когда >= 0)
#property indicator_label1  "Bull Histogram"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  3

// Буфер 1: Медвежья гистограмма (Output, когда < 0)
#property indicator_label2  "Bear Histogram"
#property indicator_type2   DRAW_HISTOGRAM
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  3

//+------------------------------------------------------------------+
//| БЛОК 2: ВНЕШНИЕ ПАРАМЕТРЫ (INPUTS)                               |
//+------------------------------------------------------------------+
input int    ATR_Period         = 2;     // Период ATR для нормализации (5...50)
input double ATR_Mult_Threshold = 1.0;    // Множитель ATR для порога разворота (0.5...5.0)
input int    MinPoints          = 200;     // Минимальный порог в пунктах (флор)
input double Sensitivity        = 0.1;    // Чувствительность tanh-нормализации (0.1...2.0)
input bool   UseYangYin         = true;   // Включить Yang/Yin (классика Nison)
input double YangYin_Boost      = 1.0;    // Усиление при пробое последнего pivot (1.0...2.0)
input bool   ShowLevels         = true;   // Рисовать уровни ±0.7

//+------------------------------------------------------------------+
//| БЛОК 3: БУФЕРЫ ИНДИКАТОРА                                        |
//+------------------------------------------------------------------+
// КОНТРАКТНЫЕ буфера (доступны через iCustom):
double BullHist[];        // Буфер 0: Output при >= 0 (видимый)
double BearHist[];        // Буфер 1: Output при < 0  (видимый)
double Direction[];       // Буфер 2: -2/-1/0/+1/+2 (для EA)
double Strength[];        // Буфер 3: |Output| в [0,1] (для EA)
double Proximity[];       // Буфер 4: 0...1 опережающий сигнал разворота (для EA)
double BarsInTrend[];     // Буфер 5: счётчик баров в тренде (для EA)

// СЛУЖЕБНЫЕ буфера (внутреннее состояние Kagi-движка):
// Хранение в буферах вместо глобальных переменных обеспечивает идемпотентность
// пересчёта и полностью устраняет репейнт при повторных вызовах OnCalculate
double Anchor[];          // Буфер 6: цена начала текущего тренда
double Extreme[];         // Буфер 7: экстремум текущего тренда
double SwingHi[];         // Буфер 8: последний swing high (для Yang)
double SwingLo[];         // Буфер 9: последний swing low (для Yin)

//+------------------------------------------------------------------+
//| Глобальные константы                                              |
//+------------------------------------------------------------------+
const double EPS         = 0.0001;     // защитный минимум от деления на 0
const double SENTINEL_HI = 1.0e10;     // sentinel: блокирует ложный Yang до первого разворота
const double SENTINEL_LO = -1.0e10;    // sentinel: блокирует ложный Yin до первого разворота

//+------------------------------------------------------------------+
//| БЛОК 4: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                  |
//+------------------------------------------------------------------+

// Гиперболический тангенс (MQL4 не имеет встроенной MathTanh)
// Возвращает значение в [-1, +1] с защитой от overflow MathExp
double MathTanhSafe(double x)
{
   // Защита от overflow MathExp при больших значениях
   if(x >  20.0) return  1.0;
   if(x < -20.0) return -1.0;
   double e_pos = MathExp(x);
   double e_neg = MathExp(-x);
   double denom = e_pos + e_neg;
   if(denom < EPS) return (x >= 0.0) ? 1.0 : -1.0;   // защита от деления на 0
   return (e_pos - e_neg) / denom;
}

// Валидация входных параметров при OnInit
bool ValidateInputs()
{
   if(ATR_Period < 2 || ATR_Period > 200)
   {
      Print("[KagiFlow] ОШИБКА: ATR_Period вне диапазона [2...200]: ", ATR_Period);
      return false;
   }
   if(ATR_Mult_Threshold <= 0.0 || ATR_Mult_Threshold > 10.0)
   {
      Print("[KagiFlow] ОШИБКА: ATR_Mult_Threshold вне диапазона (0...10]: ",
            DoubleToString(ATR_Mult_Threshold, 2));
      return false;
   }
   if(MinPoints < 0 || MinPoints > 10000)
   {
      Print("[KagiFlow] ОШИБКА: MinPoints вне диапазона [0...10000]: ", MinPoints);
      return false;
   }
   if(Sensitivity <= 0.0 || Sensitivity > 10.0)
   {
      Print("[KagiFlow] ОШИБКА: Sensitivity вне диапазона (0...10]: ",
            DoubleToString(Sensitivity, 2));
      return false;
   }
   if(YangYin_Boost < 1.0 || YangYin_Boost > 5.0)
   {
      Print("[KagiFlow] ОШИБКА: YangYin_Boost вне диапазона [1...5]: ",
            DoubleToString(YangYin_Boost, 2));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| БЛОК 5: ИНИЦИАЛИЗАЦИЯ ИНДИКАТОРА                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   // Валидация параметров
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);
   
   // Короткое имя индикатора и точность отображения
   IndicatorShortName("Kagi Flow Oscillator v1.0");
   IndicatorDigits(4);    // 4 знака для значений в диапазоне [-1, +1]
   
   // Привязка контрактных буферов (доступны через iCustom)
   SetIndexBuffer(0, BullHist);
   SetIndexBuffer(1, BearHist);
   SetIndexBuffer(2, Direction);
   SetIndexBuffer(3, Strength);
   SetIndexBuffer(4, Proximity);
   SetIndexBuffer(5, BarsInTrend);
   
   // Привязка служебных буферов (внутреннее состояние Kagi-движка)
   SetIndexBuffer(6, Anchor);
   SetIndexBuffer(7, Extreme);
   SetIndexBuffer(8, SwingHi);
   SetIndexBuffer(9, SwingLo);
   
   // Стили видимых буферов (гистограммы)
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrDodgerBlue);
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrRed);
   
   // Скрытые буфера: явно отключаем отрисовку
   SetIndexStyle(2, DRAW_NONE);
   SetIndexStyle(3, DRAW_NONE);
   SetIndexStyle(4, DRAW_NONE);
   SetIndexStyle(5, DRAW_NONE);
   SetIndexStyle(6, DRAW_NONE);
   SetIndexStyle(7, DRAW_NONE);
   SetIndexStyle(8, DRAW_NONE);
   SetIndexStyle(9, DRAW_NONE);
   
   // EMPTY_VALUE для видимых буферов (важно: не 0.0, чтобы не рисовать "нули")
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   // Для скрытых буферов 0.0 — корректное нейтральное значение
   SetIndexEmptyValue(2, 0.0);
   SetIndexEmptyValue(3, 0.0);
   SetIndexEmptyValue(4, 0.0);
   SetIndexEmptyValue(5, 0.0);
   SetIndexEmptyValue(6, 0.0);
   SetIndexEmptyValue(7, 0.0);
   SetIndexEmptyValue(8, 0.0);
   SetIndexEmptyValue(9, 0.0);
   
   // Подписи буферов в окне Data Window
   SetIndexLabel(0, "Bull");
   SetIndexLabel(1, "Bear");
   SetIndexLabel(2, "Direction");
   SetIndexLabel(3, "Strength");
   SetIndexLabel(4, "Proximity");
   SetIndexLabel(5, "BarsInTrend");
   // Служебные буфера скрываем из Data Window
   SetIndexLabel(6, NULL);
   SetIndexLabel(7, NULL);
   SetIndexLabel(8, NULL);
   SetIndexLabel(9, NULL);
   
   // Логирование настроек
   Print("[KagiFlow] Инициализирован. ATR=", ATR_Period,
         " ThrMult=", DoubleToString(ATR_Mult_Threshold, 2),
         " MinPts=", MinPoints,
         " Sens=", DoubleToString(Sensitivity, 2),
         " YangYin=", (UseYangYin ? "ON" : "OFF"),
         " Boost=", DoubleToString(YangYin_Boost, 2));
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 6: РАСЧЁТ ИНДИКАТОРА                                        |
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
   // Защита: данных недостаточно для расчёта ATR
   if(rates_total < ATR_Period + 3)
      return(0);
   
   // Определение диапазона расчёта
   int limit;
   if(prev_calculated == 0)
   {
      // Первый расчёт: проходим всю историю с запасом для ATR
      limit = rates_total - ATR_Period - 2;
      
      // Полная инициализация всех буферов
      ArrayInitialize(BullHist,    EMPTY_VALUE);
      ArrayInitialize(BearHist,    EMPTY_VALUE);
      ArrayInitialize(Direction,   0.0);
      ArrayInitialize(Strength,    0.0);
      ArrayInitialize(Proximity,   0.0);
      ArrayInitialize(BarsInTrend, 0.0);
      ArrayInitialize(Anchor,      0.0);
      ArrayInitialize(Extreme,     0.0);
      ArrayInitialize(SwingHi,     SENTINEL_HI);   // блокирует ложный Yang
      ArrayInitialize(SwingLo,     SENTINEL_LO);   // блокирует ложный Yin
   }
   else
   {
      // Инкрементальный расчёт: новые закрытые бары
      limit = rates_total - prev_calculated;
      if(limit < 1) limit = 1;   // минимум: бар i=1 (текущий i=0 не рассчитываем)
   }
   
   // Защита от выхода за границы массивов
   if(limit >= rates_total - 1) limit = rates_total - 2;
   if(limit < 1) return(prev_calculated);
   
   // ====================================================================
   // ГЛАВНЫЙ ЦИКЛ: от старых баров к новым
   // ВАЖНО: i = 0 (текущий незакрытый бар) НЕ рассчитывается — защита от репейнта
   // ====================================================================
   for(int i = limit; i >= 1; i--)
   {
      //=================================================================
      // ШАГ 1: РАСЧЁТ ATR И ПОРОГА РАЗВОРОТА
      //=================================================================
      double atr_i = iATR(_Symbol, _Period, ATR_Period, i);
      
      // Защита: невалидный ATR (например, у начала истории)
      if(atr_i <= 0.0 || atr_i == EMPTY_VALUE)
      {
         // Переносим предыдущее состояние без изменений
         if(i + 1 < rates_total)
         {
            Direction[i]   = Direction[i+1];
            Anchor[i]      = Anchor[i+1];
            Extreme[i]     = Extreme[i+1];
            SwingHi[i]     = SwingHi[i+1];
            SwingLo[i]     = SwingLo[i+1];
            BarsInTrend[i] = BarsInTrend[i+1] + 1.0;
         }
         Strength[i]    = 0.0;
         Proximity[i]   = 0.0;
         BullHist[i]    = EMPTY_VALUE;
         BearHist[i]    = EMPTY_VALUE;
         continue;
      }
      
      double atr_safe  = MathMax(atr_i, EPS);
      double threshold = MathMax(atr_i * ATR_Mult_Threshold, MinPoints * _Point);
      
      //=================================================================
      // ШАГ 2: ИНИЦИАЛИЗАЦИЯ НА САМОМ СТАРОМ РАССЧИТЫВАЕМОМ БАРЕ
      //=================================================================
      if(prev_calculated == 0 && i == limit)
      {
         Direction[i]   = +1.0;            // стартуем с UP-тренда
         Anchor[i]      = close[i];        // якорь = текущая цена
         Extreme[i]     = close[i];        // экстремум = текущая цена
         SwingHi[i]     = SENTINEL_HI;     // блокирует Yang до первого разворота
         SwingLo[i]     = SENTINEL_LO;     // блокирует Yin до первого разворота
         BarsInTrend[i] = 1.0;
         Strength[i]    = 0.0;
         Proximity[i]   = 0.0;
         BullHist[i]    = 0.0;             // стартовая гистограмма = 0
         BearHist[i]    = EMPTY_VALUE;
         continue;
      }
      
      // Защита: предыдущий бар (i+1) должен существовать
      if(i + 1 >= rates_total)
         continue;
      
      //=================================================================
      // ШАГ 3: ЧТЕНИЕ ПРЕДЫДУЩЕГО СОСТОЯНИЯ (из буферов)
      //=================================================================
      int    prevDir = (int)Direction[i+1];
      double prevExt = Extreme[i+1];
      double prevAnc = Anchor[i+1];
      double prevSwH = SwingHi[i+1];
      double prevSwL = SwingLo[i+1];
      
      //=================================================================
      // ШАГ 4: KAGI-ДВИЖОК (логика разворота)
      //=================================================================
      int    newDir   = prevDir;
      double newAnc   = prevAnc;
      double newExt   = prevExt;
      double newSwH   = prevSwH;
      double newSwL   = prevSwL;
      bool   reversed = false;
      double cur      = close[i];
      
      if(prevDir > 0)   // Текущий тренд UP (+1 или +2)
      {
         if(cur > prevExt)
         {
            // Продолжение UP-тренда: обновляем экстремум
            newExt = cur;
            newDir = +1;   // Yang будет назначен ниже (Шаг 5)
         }
         else if(cur < (prevExt - threshold))
         {
            // РАЗВОРОТ ВНИЗ
            newDir   = -1;
            newAnc   = prevExt;     // якорь = бывший экстремум UP
            newSwH   = prevExt;     // фиксируем новый swing high (для Yang в будущем)
            newExt   = cur;
            reversed = true;
         }
         else
         {
            // Тренд без обновления экстремума (откат внутри Threshold)
            newDir = +1;
         }
      }
      else if(prevDir < 0)   // Текущий тренд DOWN (-1 или -2)
      {
         if(cur < prevExt)
         {
            // Продолжение DOWN-тренда: обновляем экстремум
            newExt = cur;
            newDir = -1;
         }
         else if(cur > (prevExt + threshold))
         {
            // РАЗВОРОТ ВВЕРХ
            newDir   = +1;
            newAnc   = prevExt;     // якорь = бывший экстремум DOWN
            newSwL   = prevExt;     // фиксируем новый swing low (для Yin в будущем)
            newExt   = cur;
            reversed = true;
         }
         else
         {
            // Тренд без обновления экстремума
            newDir = -1;
         }
      }
      else   // prevDir == 0 (защитная ветка, не должна срабатывать после инициализации)
      {
         newDir = +1;
         newAnc = cur;
         newExt = cur;
         newSwH = SENTINEL_HI;
         newSwL = SENTINEL_LO;
      }
      
      //=================================================================
      // ШАГ 5: YANG/YIN УСИЛЕНИЕ (классика Steve Nison)
      //=================================================================
      if(UseYangYin)
      {
         // Yang: тренд UP пробил последний swing high (валидный, не sentinel)
         if(newDir == +1 && cur > prevSwH && prevSwH < SENTINEL_HI)
            newDir = +2;
         // Yin: тренд DOWN пробил последний swing low (валидный, не sentinel)
         if(newDir == -1 && cur < prevSwL && prevSwL > SENTINEL_LO)
            newDir = -2;
      }
      
      //=================================================================
      // ШАГ 6: ЗАПИСЬ СОСТОЯНИЯ В БУФЕРА
      //=================================================================
      Direction[i]   = (double)newDir;
      Anchor[i]      = newAnc;
      Extreme[i]     = newExt;
      SwingHi[i]     = newSwH;
      SwingLo[i]     = newSwL;
      BarsInTrend[i] = reversed ? 1.0 : (BarsInTrend[i+1] + 1.0);
      
      //=================================================================
      // ШАГ 7: РАСЧЁТ STRENGTH ЧЕРЕЗ TANH (bounded в [-1, +1])
      //=================================================================
      double rawDist = (cur - newAnc) / atr_safe;
      double boost   = (MathAbs(newDir) == 2 && UseYangYin) ? YangYin_Boost : 1.0;
      double output  = MathTanhSafe(rawDist * Sensitivity * boost);
      
      Strength[i] = MathAbs(output);
      
      //=================================================================
      // ШАГ 8: ГИСТОГРАММЫ (видимые буферы)
      //=================================================================
      if(output >= 0.0)
      {
         BullHist[i] = output;
         BearHist[i] = EMPTY_VALUE;
      }
      else
      {
         BullHist[i] = EMPTY_VALUE;
         BearHist[i] = output;
      }
      
      //=================================================================
      // ШАГ 9: REVERSAL PROXIMITY (опережающий сигнал разворота)
      //=================================================================
      double distAgainst = 0.0;
      if(newDir > 0)
         distAgainst = newExt - cur;       // откат от максимума (UP-тренд)
      else if(newDir < 0)
         distAgainst = cur - newExt;       // откат от минимума (DOWN-тренд)
      
      distAgainst = MathMax(0.0, distAgainst);
      Proximity[i] = MathMin(1.0, distAgainst / MathMax(threshold, EPS));
   }
   
   //=====================================================================
   // КОПИРОВАНИЕ СОСТОЯНИЯ НА БАР 0 (для корректного Data Window)
   // ВНИМАНИЕ: бар 0 НЕ рассчитывается, состояние = последнему закрытому
   // EA должны использовать shift=1 для гарантии отсутствия репейнта
   //=====================================================================
   if(rates_total >= 2)
   {
      Direction[0]   = Direction[1];
      Strength[0]    = Strength[1];
      Proximity[0]   = Proximity[1];
      BarsInTrend[0] = BarsInTrend[1];
      Anchor[0]      = Anchor[1];
      Extreme[0]     = Extreme[1];
      SwingHi[0]     = SwingHi[1];
      SwingLo[0]     = SwingLo[1];
      BullHist[0]    = EMPTY_VALUE;        // на текущем баре гистограмма не рисуется
      BearHist[0]    = EMPTY_VALUE;
   }
   
   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ДЕИНИЦИАЛИЗАЦИЯ                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // В данной версии графических объектов не используется
   // Логирование причины деинициализации для отладки
   string reasonStr = "";
   switch(reason)
   {
      case REASON_PROGRAM:       reasonStr = "PROGRAM";       break;
      case REASON_REMOVE:        reasonStr = "REMOVE";        break;
      case REASON_RECOMPILE:     reasonStr = "RECOMPILE";     break;
      case REASON_CHARTCHANGE:   reasonStr = "CHARTCHANGE";   break;
      case REASON_CHARTCLOSE:    reasonStr = "CHARTCLOSE";    break;
      case REASON_PARAMETERS:    reasonStr = "PARAMETERS";    break;
      case REASON_ACCOUNT:       reasonStr = "ACCOUNT";       break;
      default:                   reasonStr = "OTHER ("+IntegerToString(reason)+")"; break;
   }
   Print("[KagiFlow] Деинициализация. Причина: ", reasonStr);
}

//+------------------------------------------------------------------+
//| КОНЕЦ ФАЙЛА                                                       |
//+------------------------------------------------------------------+
