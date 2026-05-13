//+------------------------------------------------------------------+
//|                                       osc_FractalAMA_v5_0.mq4   |
//+------------------------------------------------------------------+
//
//  БЛОК 1: ЗАГОЛОВОК
//
//  Алгоритм:    Осциллятор циклов на основе FRAMA (Fractal Adaptive MA)
//  Формула:     (Close - Signal) / ATR × Multiplier × (2.0 - dim)
//  Основа:      ma_FractalAMA_v4_0.mq4 (Ehlers / Kennel)
//  Автор:       Александр Ковальчук (2026)
//
//  v5.0 — Новый осциллятор (на базе v4.0):
//    + Гистограмма в отдельном окне (аналог MACD)
//    + Позиция (выше/ниже нуля): Close vs Signal
//    + Цвет (синий/красный): Close vs FRAMA (быстрый сигнал)
//    + ATR-нормализация высоты (универсально для всех пар)
//    + dim-модуляция: тренд=высокая, шум=нулевая
//    + Скрытый буфер Direction (+1/-1) для EA
//    + Скрытый буфер Dim для EA
//    - Удалены: стрелки, двухцветная линия FRAMA, Signal линия
//
//  Три слоя информации в одной гистограмме:
//    1) Позиция: Close > Signal → выше нуля (BUY зона)
//    2) Цвет:    Close > FRAMA → синий (бычья фаза цикла)
//    3) Высота:  |Close-Signal|/ATR × dim_factor → сила + качество
//
//  ИНТЕГРАЦИЯ В EA (iCustom):
//    double bull = iCustom(Symbol(),0,"osc_FractalAMA_v5_0",
//                          4,6.10,10.0,14,100.0,   0,1);  // бычья гистограмма
//    double bear = iCustom(Symbol(),0,"osc_FractalAMA_v5_0",
//                          4,6.10,10.0,14,100.0,   1,1);  // медвежья гистограмма
//    double dir  = iCustom(Symbol(),0,"osc_FractalAMA_v5_0",
//                          4,6.10,10.0,14,100.0,   2,1);  // направление ±1
//    double dim  = iCustom(Symbol(),0,"osc_FractalAMA_v5_0",
//                          4,6.10,10.0,14,100.0,   3,1);  // размерность
//
//    if(dir > 0)  → BUY  зона
//    if(dir < 0)  → SELL зона
//    if(bull != EMPTY_VALUE) → FRAMA бычья
//    if(bear != EMPTY_VALUE) → FRAMA медвежья
//    if(dim < 1.3) → сильный тренд
//    if(dim > 1.6) → флэт/шум
//
//  РЕКОМЕНДУЕМЫЕ ПАРАМЕТРЫ:
//    Все TF:  RPeriod=4, multiplier=6.10, signal_multiplier=10.0
//    Масштаб: ATR_Multiplier=100 (подстроить визуально)
//
#property copyright "Copyright 2026, Ruslan Kuchma"
#property link      "https://t.me/RuslanKuchma"
#property strict

//+------------------------------------------------------------------+
//  БЛОК 2: PROPERTIES — СВОЙСТВА ИНДИКАТОРА
//+------------------------------------------------------------------+
#property indicator_separate_window        // осциллятор в отдельном окне
#property indicator_buffers 2              // 2 видимых буфера (гистограммы)
#property indicator_color1  DodgerBlue     // буфер 0: бычья гистограмма
#property indicator_color2  Red            // буфер 1: медвежья гистограмма

//--- нулевая линия (разделитель)
#property indicator_level1     0.0
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT
#property indicator_levelwidth 1

//+------------------------------------------------------------------+
//  БЛОК 3: ВНЕШНИЕ ПАРАМЕТРЫ
//+------------------------------------------------------------------+
extern int    RPeriod           = 4;      // Период FRAMA (форсируется чётным, мин. 4)
extern double multiplier        = 4.6;   // Скорость адаптации FRAMA (Элерс: 4.6)
extern double signal_multiplier = 2.5;   // Скорость адаптации Signal (Кеннел: 2.5)
extern int    ATR_Period        = 14;     // Период ATR для нормализации высоты
extern double ATR_Multiplier    = 100.0;  // Множитель масштаба гистограммы

//+------------------------------------------------------------------+
//  БЛОК 4: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
//+------------------------------------------------------------------+

//--- видимые буферы (гистограммы) ---
double g_BullHist[];   // буфер 0: бычья гистограмма (DodgerBlue)
double g_BearHist[];   // буфер 1: медвежья гистограмма (Red)

//--- скрытые буферы ---
double g_Direction[];  // буфер 2: направление тренда (+1.0 / -1.0 / 0.0)
                       //   EA: iCustom(..., 2, shift)
double g_Dim[];        // буфер 3: фрактальная размерность dim ∈ [1.0, 2.0]
                       //   EA: iCustom(..., 3, shift)

//--- рабочие массивы (не буферы индикатора) ---
//    хранят промежуточные значения FRAMA и Signal
//    для расчёта гистограммы на каждом баре
double g_Frama[];      // значение FRAMA на каждом баре
double g_Signal[];     // значение Signal на каждом баре

//--- рабочие переменные ---
int g_N;               // чётный период (вычисляется в OnInit из RPeriod)

//+------------------------------------------------------------------+
//  БЛОК 5: OnInit() — ИНИЦИАЛИЗАЦИЯ
//+------------------------------------------------------------------+
int OnInit()
{
   //--- форсируем чётный период, минимум 4
   g_N = (int)MathFloor(RPeriod / 2.0) * 2;
   if(g_N < 4) g_N = 4;

   //--- валидация параметров
   if(ATR_Period < 1)        ATR_Period = 14;
   if(ATR_Multiplier <= 0.0) ATR_Multiplier = 100.0;

   //--- регистрируем 6 буферов (2 видимых + 2 скрытых + 2 рабочих)
   IndicatorBuffers(6);

   SetIndexBuffer(0, g_BullHist);
   SetIndexBuffer(1, g_BearHist);
   SetIndexBuffer(2, g_Direction);
   SetIndexBuffer(3, g_Dim);
   SetIndexBuffer(4, g_Frama);   // рабочий: значение FRAMA
   SetIndexBuffer(5, g_Signal);  // рабочий: значение Signal

   //--- стиль видимых буферов (гистограммы)
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, 3);  // бычья — синяя
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, 3);  // медвежья — красная

   //--- скрытые буферы — не рисуются
   SetIndexStyle(2, DRAW_NONE);  // Direction
   SetIndexStyle(3, DRAW_NONE);  // Dim
   SetIndexStyle(4, DRAW_NONE);  // FRAMA (рабочий)
   SetIndexStyle(5, DRAW_NONE);  // Signal (рабочий)

   //--- метки для Data Window
   SetIndexLabel(0, "FRAMA Bull");
   SetIndexLabel(1, "FRAMA Bear");
   SetIndexLabel(2, "Direction");
   SetIndexLabel(3, "Dimension");
   SetIndexLabel(4, NULL);  // скрыть из Data Window
   SetIndexLabel(5, NULL);  // скрыть из Data Window

   //--- пустые значения
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, EMPTY_VALUE);
   SetIndexEmptyValue(3, EMPTY_VALUE);
   SetIndexEmptyValue(4, EMPTY_VALUE);
   SetIndexEmptyValue(5, EMPTY_VALUE);

   //--- строка в заголовке окна
   IndicatorShortName("FRAMA_OSC(" + IntegerToString(g_N)
                      + ",m" + DoubleToStr(multiplier, 1)
                      + ",s" + DoubleToStr(signal_multiplier, 1) + ")");
   IndicatorDigits(2);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//  БЛОК 6: start() — ОСНОВНОЙ РАСЧЁТ
//+------------------------------------------------------------------+
int start()
{
   //--- проверка минимума баров
   //    DEst(shift, g_N): shift + g_N - 1 < Bars
   //    Плюс ATR_Period баров для iATR
   int minBars = g_N + (int)MathMax(ATR_Period, 4) + 2;
   if(Bars < minBars) return(0);

   int counted = IndicatorCounted();
   if(counted < 0) return(-1);

   //--- максимальный безопасный сдвиг:
   //    DEst(shift, g_N): shift + g_N - 1 < Bars → shift < Bars - g_N + 1
   //    запас -2 для инициализации
   int maxshift = Bars - g_N - 2;

   int limit;
   if(counted <= 0)
   {
      //--- первый запуск: инициализируем стартовую точку
      g_Frama[maxshift]    = Close[maxshift];
      g_Signal[maxshift]   = Close[maxshift];
      g_BullHist[maxshift] = EMPTY_VALUE;
      g_BearHist[maxshift] = EMPTY_VALUE;
      g_Direction[maxshift] = 0.0;
      g_Dim[maxshift]      = 1.5;   // нейтральное начальное значение
      limit = maxshift - 1;
   }
   else
   {
      //--- инкрементальный режим: только новые бары
      limit = Bars - counted;
      if(limit > maxshift - 1) limit = maxshift - 1;
      if(limit < 1)            limit = 1;
   }

   // ==============================================================
   // ОСНОВНОЙ ЦИКЛ: от старых баров к новым
   //   Диапазон: от limit до 1 (включительно)
   //   Bar[0] обрабатывается отдельно (только визуализация)
   // ==============================================================
   for(int shift = limit; shift >= 1; shift--)
   {
      // =========================================================
      // ШАГ 1: фрактальная размерность Элерса
      // =========================================================
      double dim = DEst(shift, g_N);
      g_Dim[shift] = dim;

      // =========================================================
      // ШАГ 2: адаптивные коэффициенты сглаживания
      //   dim=1.0 (тренд)  → alpha → 1.0  (быстрая)
      //   dim=1.5 (рынок)  → alpha ≈ 0.10 (средняя)
      //   dim=2.0 (шум)    → alpha → 0.01 (замерла)
      // =========================================================
      double alpha  = MathMax(0.01, MathMin(1.0,
                              MathExp(-multiplier        * (dim - 1.0))));
      double alphas = MathMax(0.01, MathMin(1.0,
                              MathExp(-signal_multiplier * (dim - 1.0))));

      // =========================================================
      // ШАГ 3: предыдущее значение FRAMA
      // =========================================================
      double prev_frama = g_Frama[shift + 1];
      if(prev_frama == EMPTY_VALUE) prev_frama = Close[shift + 1];

      double prev_signal = g_Signal[shift + 1];
      if(prev_signal == EMPTY_VALUE) prev_signal = Close[shift + 1];

      // =========================================================
      // ШАГ 4: EMA с адаптивным alpha
      //   FRAMA[i]  = alpha  × Close[i]  + (1-alpha)  × FRAMA[i-1]
      //   Signal[i] = alphas × FRAMA[i]  + (1-alphas) × Signal[i-1]
      // =========================================================
      double frama  = alpha  * Close[shift] + (1.0 - alpha)  * prev_frama;
      double signal = alphas * frama        + (1.0 - alphas) * prev_signal;

      //--- сохраняем в рабочие массивы
      g_Frama[shift]  = frama;
      g_Signal[shift] = signal;

      // =========================================================
      // ШАГ 5: расчёт гистограммы
      // =========================================================

      //--- знаковое расстояние Close до Signal
      double distance = Close[shift] - signal;

      //--- ATR-нормализация
      double atr = iATR(NULL, 0, ATR_Period, shift);
      double normalized;
      if(atr > 0.0)
         normalized = distance / atr;      // безразмерная величина ≈ [-3, +3]
      else
         normalized = 0.0;                 // защита от деления на 0

      //--- dim-модуляция высоты:
      //    dim=1.0 → factor=1.0 (тренд: полная высота)
      //    dim=1.5 → factor=0.5 (переход: половина)
      //    dim=2.0 → factor=0.0 (шум: нулевая)
      double dim_factor = MathMax(0.0, 2.0 - dim);

      //--- итоговая высота гистограммы
      double histogram = normalized * ATR_Multiplier * dim_factor;

      // =========================================================
      // ШАГ 6: цвет гистограммы — Close vs FRAMA
      //   Close > FRAMA → синий (бычья фаза)
      //   Close < FRAMA → красный (медвежья фаза)
      //   Close == FRAMA → предыдущий цвет (защита от дребезга)
      // =========================================================
      bool is_bull;
      if(Close[shift] > frama)
         is_bull = true;
      else if(Close[shift] < frama)
         is_bull = false;
      else
      {
         //--- Close == FRAMA: наследуем предыдущий цвет
         is_bull = (g_BullHist[shift + 1] != EMPTY_VALUE);
      }

      //--- заполнение видимых буферов
      if(is_bull)
      {
         g_BullHist[shift] = histogram;    // синяя гистограмма
         g_BearHist[shift] = EMPTY_VALUE;  // красная — пусто
      }
      else
      {
         g_BearHist[shift] = histogram;    // красная гистограмма
         g_BullHist[shift] = EMPTY_VALUE;  // синяя — пусто
      }

      // =========================================================
      // ШАГ 7: буфер направления для EA
      //   Close > Signal → +1.0 (BUY зона)
      //   Close < Signal → -1.0 (SELL зона)
      // =========================================================
      if(distance > 0.0)
         g_Direction[shift] = 1.0;
      else if(distance < 0.0)
         g_Direction[shift] = -1.0;
      else
         g_Direction[shift] = 0.0;         // точно на Signal — нейтрал

   } // end for

   // ==============================================================
   // ОБНОВЛЕНИЕ BAR[0] (текущий незакрытый бар)
   //   Визуализация FRAMA, Signal, гистограммы — для наглядности.
   //   Direction[0] = 0 — EA НЕ использует незакрытый бар.
   // ==============================================================
   {
      double dim_0 = DEst(0, g_N);
      g_Dim[0] = dim_0;

      double a0  = MathMax(0.01, MathMin(1.0, MathExp(-multiplier        * (dim_0 - 1.0))));
      double as0 = MathMax(0.01, MathMin(1.0, MathExp(-signal_multiplier * (dim_0 - 1.0))));

      double pf0 = g_Frama[1];
      if(pf0 == EMPTY_VALUE) pf0 = Close[1];

      double ps0 = g_Signal[1];
      if(ps0 == EMPTY_VALUE) ps0 = Close[1];

      double fr0  = a0  * Close[0] + (1.0 - a0)  * pf0;
      double sig0 = as0 * fr0      + (1.0 - as0) * ps0;

      g_Frama[0]  = fr0;
      g_Signal[0] = sig0;

      //--- гистограмма bar[0] (визуализация)
      double dist0 = Close[0] - sig0;
      double atr0  = iATR(NULL, 0, ATR_Period, 0);
      double norm0 = (atr0 > 0.0) ? (dist0 / atr0) : 0.0;
      double dimf0 = MathMax(0.0, 2.0 - dim_0);
      double hist0 = norm0 * ATR_Multiplier * dimf0;

      bool bull0;
      if(Close[0] > fr0)
         bull0 = true;
      else if(Close[0] < fr0)
         bull0 = false;
      else
         bull0 = (g_BullHist[1] != EMPTY_VALUE);

      if(bull0)
      {
         g_BullHist[0] = hist0;
         g_BearHist[0] = EMPTY_VALUE;
      }
      else
      {
         g_BearHist[0] = hist0;
         g_BullHist[0] = EMPTY_VALUE;
      }

      //--- Direction на bar[0] = 0 (EA не использует!)
      g_Direction[0] = 0.0;
   }

   return(0);
}

//+------------------------------------------------------------------+
//  БЛОК 7: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
//+------------------------------------------------------------------+

//-------------------------------------------------------------------+
//  DEst() — оценка фрактальной размерности (алгоритм Элерса)
//
//  Оптимизация v2.0: однопроходный поиск High/Low
//    Было: 6 вызовов Highest()/Lowest() + 3 прохода по массиву
//    Стало: 2 прохода по n2 баров каждый → ускорение ~3×
//
//  Параметры:
//    shift — индекс стартового бара
//    n     — период расчёта (чётное число)
//
//  Возвращает: dim ∈ [1.0, 2.0]
//    1.0 = идеальный тренд (alpha → 1.0, MA быстрая)
//    1.5 = случайное блуждание
//    2.0 = чистый шум/флет (alpha → 0.01, MA почти неподвижна)
//-------------------------------------------------------------------+
double DEst(int shift, int n)
{
   int n2 = n / 2;

   //--- поиск High/Low первой половины [shift .. shift+n2-1]
   double hi1 = High[shift], lo1 = Low[shift];
   for(int j = shift + 1; j < shift + n2; j++)
   {
      if(High[j] > hi1) hi1 = High[j];
      if(Low[j]  < lo1) lo1 = Low[j];
   }

   //--- поиск High/Low второй половины [shift+n2 .. shift+n-1]
   double hi2 = High[shift + n2], lo2 = Low[shift + n2];
   for(int j = shift + n2 + 1; j < shift + n; j++)
   {
      if(High[j] > hi2) hi2 = High[j];
      if(Low[j]  < lo2) lo2 = Low[j];
   }

   //--- нормализованные диапазоны по Элерсу
   double r1 = (hi1 - lo1) / n2;
   double r2 = (hi2 - lo2) / n2;
   double r3 = (MathMax(hi1, hi2) - MathMin(lo1, lo2)) / n;

   //--- защита от деления на 0 (флет, гэпы, каникулы)
   if(r3 <= 0.0 || (r1 + r2) <= 0.0) return(1.5);

   //--- формула фрактальной размерности:
   //    dim = (ln(R1+R2) - ln(R3)) × log₂(e)
   return((MathLog(r1 + r2) - MathLog(r3)) * 1.442695);
}

//+------------------------------------------------------------------+
//  БЛОК 8: OnDeinit() — ОЧИСТКА
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}
//+------------------------------------------------------------------+
