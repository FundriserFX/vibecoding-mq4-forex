//+------------------------------------------------------------------+
//|                                    PSAR_VWAP_Blend_v1_0.mq4     |
//|        SAR-VWAP Blend: Parabolic SAR + Volume-Weighted Smoothing  |
//|                                   Copyright © 2026, Ruslan Kuchma|
//+------------------------------------------------------------------+
//| ТЕХНИЧЕСКОЕ ЗАДАНИЕ                                               |
//|                                                                   |
//| КОНЦЕПЦИЯ:                                                        |
//|   Точечный трендовый индикатор на базе Parabolic SAR (0.02;0.2), |
//|   позиции точек сглажены через скользящий VWAP с весом по         |
//|   тиковому объёму. Синие точки = uptrend, красные = downtrend.   |
//|   Меньше ложных реверсов, чем у чистого SAR.                     |
//|                                                                   |
//| АЛГОРИТМ (Volume-Blended SAR):                                   |
//|   1. SAR_val  = iSAR(Step, Max, i) — базовый уровень             |
//|   2. VWAP_val = скользящий VWAP за N баров от бара i             |
//|      TypPrice = (High + Low + Close) / 3                         |
//|      VWAP = Σ(TypPrice×Vol) / Σ(Vol)                            |
//|   3. weight = vol[i] / (2 × avgVol), зажат [0..1]               |
//|      vol > 2×avgVol → weight=1.0 → точка = SAR (сильный сигнал) |
//|      vol = avgVol   → weight=0.5 → точка = середина SAR и VWAP  |
//|      vol = 0        → weight=0.0 → точка = VWAP (тихий рынок)   |
//|   4. Dot = SAR × weight + VWAP × (1 - weight)                   |
//|   5. Направление: Close > SAR → синий; Close < SAR → красный    |
//|                                                                   |
//| АНТИРЕПЕЙНТ:                                                      |
//|   Все расчёты на bar[1] и старше. Bar[0] явно = EMPTY_VALUE.    |
//|   Точки не исчезают и не перемещаются после фиксации.            |
//|                                                                   |
//| БУФЕРЫ ДЛЯ EA (iCustom):                                         |
//|   Буфер 0 = BuyTrail  — синие точки (uptrend, значение = dot)    |
//|   Буфер 1 = SellTrail — красные точки (downtrend, значение = dot)|
//|   Буфер 2 = Signal    — +1 (buy) / -1 (sell) / 0 (нет)          |
//|   Буфер 3 = SARVWAP   — числовое значение бленда на каждом баре  |
//|                                                                   |
//| ПРИМЕР ВЫЗОВА iCustom ИЗ EA:                                      |
//|   double sig = iCustom(NULL, 0, "PSAR_VWAP_Blend_v1_0",          |
//|                        0.02, 0.20, 20,                            |
//|                        clrDodgerBlue, clrCrimson, 2,             |
//|                        false, false, false, false,               |
//|                        2, 1);   // буфер 2 (Signal), бар 1       |
//|   if(sig > 0.5)  → Buy trend                                      |
//|   if(sig < -0.5) → Sell trend                                     |
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "1.00"
#property strict
#property description "PSAR-VWAP Blend v1.0 — Parabolic SAR + Rolling VWAP"
#property description "Точки: синие (uptrend), красные (downtrend)"
#property description "Блендинг: высокий объём → SAR доминирует, низкий → VWAP"
#property description "Антирепейнт: bar[0] не используется"

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTIES                                                |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 4

// Буфер 0: синие точки (uptrend)
#property indicator_label1  "BuyTrail"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  1

// Буфер 1: красные точки (downtrend)
#property indicator_label2  "SellTrail"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrRed
#property indicator_width2  1

// Буфер 2: скрытый — сигнал для EA
#property indicator_label3  "Signal"
#property indicator_type3   DRAW_NONE

// Буфер 3: скрытый — числовое значение бленда для EA
#property indicator_label4  "SARVWAP"
#property indicator_type4   DRAW_NONE

//+------------------------------------------------------------------+
//| БЛОК 2: ВХОДНЫЕ ПАРАМЕТРЫ                                         |
//+------------------------------------------------------------------+

// --- PARABOLIC SAR ---
input string   S0             = "=== PARABOLIC SAR ===";    // ══════════════════
input double   SAR_Step       = 0.1;                        // Шаг SAR (0.01-0.10)
input double   SAR_Max        = 0.50;                        // Макс. AF SAR (0.10-0.50)

// --- VWAP СГЛАЖИВАНИЕ ---
input string   S1             = "=== VWAP СГЛАЖИВАНИЕ ==="; // ══════════════════
input int      VWAP_Period    = 5;                          // Период скользящего VWAP (5-200)

// --- ВИЗУАЛИЗАЦИЯ ---
input string   S2             = "=== ВИЗУАЛИЗАЦИЯ ===";     // ══════════════════
input color    Color_Buy      = clrDodgerBlue;               // Цвет точек uptrend
input color    Color_Sell     = clrRed;                  // Цвет точек downtrend
input int      DotSize        = 1;                           // Размер точек (1-5)

// --- АЛЕРТЫ ---
input string   S3             = "=== АЛЕРТЫ ===";           // ══════════════════
input bool     AlertOnSignal  = false;                       // Алерт при смене тренда
input bool     UseSoundAlert  = false;                       // Звуковой алерт
input bool     UseEmailAlert  = false;                       // Email алерт
input bool     UsePushAlert   = false;                       // Push-уведомление

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                     |
//+------------------------------------------------------------------+

// --- Индикаторные буферы ---
double BuyTrailBuf[];    // Буфер 0: синие точки (uptrend)
double SellTrailBuf[];   // Буфер 1: красные точки (downtrend)
double SignalBuf[];      // Буфер 2: сигнал +1/-1/0 (скрытый, для EA)
double SARVWAPBuf[];     // Буфер 3: значение бленда (скрытый, для EA)

// --- Валидированные копии входных параметров ---
double g_sarStep;        // шаг SAR
double g_sarMax;         // максимальный AF SAR
int    g_vwapPeriod;     // период скользящего VWAP

// --- Состояние алертов ---
datetime g_lastAlertTime = 0;   // время последнего алерта
int      g_lastAlertDir  = 0;   // направление последнего алерта (+1/-1)

//+------------------------------------------------------------------+
//| БЛОК 4: ИНИЦИАЛИЗАЦИЯ (OnInit)                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // ═══ Валидация и коррекция входных параметров ═══

   g_sarStep    = MathMax(0.01, MathMin(SAR_Step, 0.10));
   g_sarMax     = MathMax(0.10, MathMin(SAR_Max, 0.50));
   g_vwapPeriod = MathMax(5, MathMin(VWAP_Period, 200));

   // SAR_Step не может быть больше SAR_Max
   if(g_sarStep >= g_sarMax)
   {
      g_sarStep = 0.02;
      g_sarMax  = 0.20;
      Print("⚠ PSAR-VWAP: SAR_Step >= SAR_Max. Восстановлено: Step=0.02, Max=0.20");
   }

   // Логирование автокоррекций
   if(MathAbs(g_sarStep - SAR_Step) > 0.0001)
      Print("⚠ PSAR-VWAP: SAR_Step скорректирован → ", DoubleToString(g_sarStep, 3));
   if(MathAbs(g_sarMax - SAR_Max) > 0.0001)
      Print("⚠ PSAR-VWAP: SAR_Max скорректирован → ", DoubleToString(g_sarMax, 2));
   if(g_vwapPeriod != VWAP_Period)
      Print("⚠ PSAR-VWAP: VWAP_Period скорректирован → ", g_vwapPeriod);

   // ═══ Регистрация буферов ═══
   SetIndexBuffer(0, BuyTrailBuf);
   SetIndexBuffer(1, SellTrailBuf);
   SetIndexBuffer(2, SignalBuf);
   SetIndexBuffer(3, SARVWAPBuf);

   // Стили отрисовки
   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, DotSize, Color_Buy);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, DotSize, Color_Sell);
   SetIndexStyle(2, DRAW_NONE);
   SetIndexStyle(3, DRAW_NONE);

   // Код 159 = точка-булет (идентично стандартному Parabolic SAR)
   SetIndexArrow(0, 159);
   SetIndexArrow(1, 159);

   // Подписи в Data Window
   SetIndexLabel(0, "BuyTrail");
   SetIndexLabel(1, "SellTrail");
   SetIndexLabel(2, "Signal");
   SetIndexLabel(3, "SARVWAP");

   // Пустые значения (MT4 не рисует точку при EMPTY_VALUE)
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, 0.0);
   SetIndexEmptyValue(3, EMPTY_VALUE);

   // Инициализация буферов пустыми значениями
   ArrayInitialize(BuyTrailBuf,  EMPTY_VALUE);
   ArrayInitialize(SellTrailBuf, EMPTY_VALUE);
   ArrayInitialize(SignalBuf,    0.0);
   ArrayInitialize(SARVWAPBuf,   EMPTY_VALUE);

   // Краткое имя индикатора на графике
   IndicatorShortName("PSAR-VWAP(" +
                      DoubleToString(g_sarStep, 2) + ";" +
                      DoubleToString(g_sarMax,  2) + ";" +
                      IntegerToString(g_vwapPeriod) + ")");
   IndicatorDigits(_Digits);

   Print("PSAR-VWAP Blend v1.0 инициализирован | ",
         "SAR=", DoubleToString(g_sarStep, 3), "/", DoubleToString(g_sarMax, 2),
         " | VWAP=", g_vwapPeriod, " баров");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 5: ОСНОВНОЙ РАСЧЁТ (OnCalculate)                             |
//+------------------------------------------------------------------+
int OnCalculate(const int      rates_total,
                const int      prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   // ─── Проверка минимального количества баров ───
   // Нужно: g_vwapPeriod баров для VWAP + 2 бара буфера + 1 бар защиты bar[0]
   int minRequired = g_vwapPeriod + 3;
   if(rates_total < minRequired)
      return(0);

   // ─── Расчёт количества баров для пересчёта ───
   int limit;
   if(prev_calculated == 0)
   {
      // Первый запуск: пересчёт всей истории
      limit = rates_total - minRequired;

      // Полный сброс буферов перед пересчётом истории
      ArrayInitialize(BuyTrailBuf,  EMPTY_VALUE);
      ArrayInitialize(SellTrailBuf, EMPTY_VALUE);
      ArrayInitialize(SignalBuf,    0.0);
      ArrayInitialize(SARVWAPBuf,   EMPTY_VALUE);
   }
   else
   {
      // Новый тик: пересчитываем только свежие бары + 1 запас
      limit = rates_total - prev_calculated + 1;
   }

   // Защита: никогда не трогаем bar[0], не выходим за историю
   if(limit > rates_total - 2) limit = rates_total - 2;
   if(limit < 1)               limit = 1;

   // ─── Основной расчётный цикл ───
   // Цикл от старых баров к новым (i = limit..1)
   // АНТИРЕПЕЙНТ: нижняя граница i >= 1 (bar[0] никогда не вычисляется)
   for(int i = limit; i >= 1; i--)
   {
      // ── ШАГ 1: Стандартный Parabolic SAR ──
      // iSAR возвращает значение SAR на закрытом баре i
      double sar = iSAR(NULL, 0, g_sarStep, g_sarMax, i);

      // Защита от некорректного значения iSAR
      if(sar <= 0.0 || sar == EMPTY_VALUE)
      {
         BuyTrailBuf[i]  = EMPTY_VALUE;
         SellTrailBuf[i] = EMPTY_VALUE;
         SignalBuf[i]    = 0.0;
         SARVWAPBuf[i]   = EMPTY_VALUE;
         continue;
      }

      // ── ШАГ 2: Скользящий VWAP за g_vwapPeriod баров ──
      // CalcRollingVWAP включает текущий бар i в расчёт VWAP
      double vwap = CalcRollingVWAP(high, low, close, tick_volume, i, g_vwapPeriod, rates_total);

      // Защита от нулевого объёма (нет данных)
      if(vwap <= 0.0)
      {
         BuyTrailBuf[i]  = EMPTY_VALUE;
         SellTrailBuf[i] = EMPTY_VALUE;
         SignalBuf[i]    = 0.0;
         SARVWAPBuf[i]   = EMPTY_VALUE;
         continue;
      }

      // ── ШАГ 3: Средний объём (исключаем бар i → начинаем с i+1) ──
      // Среднее за g_vwapPeriod баров до текущего, без текущего
      double avgVol = CalcAvgVolume(tick_volume, i + 1, g_vwapPeriod, rates_total);

      // ── ШАГ 4: Весовой коэффициент по объёму ──
      // weight = vol[i] / (2 × avgVol), зажат в [0.0 .. 1.0]
      // Логика:
      //   vol[i] = 2×avgVol → weight = 1.0 → dot = SAR (максимальное доверие движению)
      //   vol[i] = avgVol   → weight = 0.5 → dot = (SAR + VWAP) / 2
      //   vol[i] = 0        → weight = 0.0 → dot = VWAP (нет активности — держимся VWAP)
      double weight;
      if(avgVol > 0.0)
         weight = MathMin((double)tick_volume[i] / (2.0 * avgVol), 1.0);
      else
         weight = 0.5;    // объём недоступен → равновесное смешивание

      // ── ШАГ 5: Блендинг SAR + VWAP с весом по объёму ──
      double blended = NormalizeDouble(sar * weight + vwap * (1.0 - weight), _Digits);

      // ── ШАГ 6: Определение направления тренда (close vs SAR) ──
      // Направление тренда определяется стандартным SAR (не blended значением)
      // Это гарантирует корректный флип при развороте
      int dir;
      if(close[i] > sar + _Point)
         dir = 1;     // uptrend → синяя точка
      else if(close[i] < sar - _Point)
         dir = -1;    // downtrend → красная точка
      else
         dir = 0;     // цена вплотную к SAR → нейтрально

      // ── ШАГ 7: Запись в буферы ──
      SARVWAPBuf[i] = blended;   // числовое значение для EA (всегда)

      if(dir == 1)
      {
         // Uptrend: синяя точка в buфере BuyTrail
         BuyTrailBuf[i]  = blended;
         SellTrailBuf[i] = EMPTY_VALUE;
         SignalBuf[i]    = 1.0;
      }
      else if(dir == -1)
      {
         // Downtrend: красная точка в буфере SellTrail
         SellTrailBuf[i] = blended;
         BuyTrailBuf[i]  = EMPTY_VALUE;
         SignalBuf[i]    = -1.0;
      }
      else
      {
         // Нейтральная зона: ни одной точки
         BuyTrailBuf[i]  = EMPTY_VALUE;
         SellTrailBuf[i] = EMPTY_VALUE;
         SignalBuf[i]    = 0.0;
      }
   } // конец основного цикла

   // ─── АНТИРЕПЕЙНТ: явное обнуление bar[0] ───
   // Bar[0] — незакрытая свеча, никогда не участвует в расчёте
   BuyTrailBuf[0]  = EMPTY_VALUE;
   SellTrailBuf[0] = EMPTY_VALUE;
   SignalBuf[0]    = 0.0;
   SARVWAPBuf[0]   = EMPTY_VALUE;

   // ─── Алерты при смене тренда ───
   CheckAlerts(time);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| CalcRollingVWAP — скользящий VWAP за period баров                 |
//|                                                                    |
//| Формула: VWAP = Σ(TypPrice[j] × Vol[j]) / Σ(Vol[j])             |
//|   TypPrice = (High + Low + Close) / 3                             |
//|   j = [startBar .. startBar + period - 1]                        |
//|                                                                    |
//| Защита: минимальный объём = 1 тик (вместо 0 для расчёта)          |
//| Возвращает 0.0 если нет данных (вызывающий код проверяет)         |
//+------------------------------------------------------------------+
double CalcRollingVWAP(const double &h[],
                       const double &l[],
                       const double &c[],
                       const long   &vol[],
                       int           startBar,
                       int           period,
                       int           total)
{
   double sumPV = 0.0;   // сумма (типовая_цена × объём)
   double sumV  = 0.0;   // сумма объёмов

   for(int j = startBar; j < startBar + period && j < total; j++)
   {
      // Типовая цена бара j
      double typPrice = (h[j] + l[j] + c[j]) / 3.0;

      // Тиковый объём (минимум 1 для корректного взвешивания)
      double v = (double)vol[j];
      if(v < 1.0) v = 1.0;

      sumPV += typPrice * v;
      sumV  += v;
   }

   // Защита от деления на ноль
   if(sumV < 1.0) return(0.0);

   return(sumPV / sumV);
}

//+------------------------------------------------------------------+
//| CalcAvgVolume — средний тиковый объём за period баров             |
//|                                                                    |
//| startBar = i+1 чтобы текущий бар НЕ влиял на своё среднее        |
//| Возвращает 0.0 если нет данных                                     |
//+------------------------------------------------------------------+
double CalcAvgVolume(const long &vol[],
                     int         startBar,
                     int         period,
                     int         total)
{
   double sum = 0.0;
   int    cnt = 0;

   for(int j = startBar; j < startBar + period && j < total; j++)
   {
      sum += (double)vol[j];
      cnt++;
   }

   return(cnt > 0 ? sum / (double)cnt : 0.0);
}

//+------------------------------------------------------------------+
//| CheckAlerts — алерт только при СМЕНЕ направления тренда           |
//|                                                                    |
//| Проверяет bar[1] (последний закрытый бар). Один алерт на бар.     |
//| Алертит только при переходе buy→sell или sell→buy (не на каждый   |
//| баре тренда). 4 канала: Alert, Sound, Email, Push.                |
//+------------------------------------------------------------------+
void CheckAlerts(const datetime &time[])
{
   if(!AlertOnSignal) return;

   // Нет сигнала на bar[1] → выход
   if(SignalBuf[1] == 0.0) return;

   // Защита от повторного алерта на том же баре
   if(time[1] <= g_lastAlertTime) return;

   int curDir = (int)SignalBuf[1];   // +1 или -1

   // Алерт только при смене направления
   if(curDir == g_lastAlertDir) return;

   // Фиксируем новое состояние
   g_lastAlertTime = time[1];
   g_lastAlertDir  = curDir;

   // Формируем сообщение
   string dir = (curDir > 0) ? "BUY ↑  (Uptrend начат)" : "SELL ↓  (Downtrend начат)";
   string msg = "PSAR-VWAP: " + dir
              + " | Dot=" + DoubleToString(SARVWAPBuf[1], _Digits)
              + " | " + _Symbol
              + " " + EnumToString((ENUM_TIMEFRAMES)_Period);

   // Отправка по четырём каналам
   Alert(msg);
   if(UseSoundAlert) PlaySound("alert.wav");
   if(UseEmailAlert) SendMail("PSAR-VWAP Blend v1.0 | " + _Symbol, msg);
   if(UsePushAlert)  SendNotification(msg);
}

//+------------------------------------------------------------------+
//| БЛОК 7: OnDeinit — деинициализация                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");   // очистить комментарий на графике (если был)
   Print("PSAR-VWAP Blend v1.0 деинициализирован. Код: ", reason);
}
//+------------------------------------------------------------------+
