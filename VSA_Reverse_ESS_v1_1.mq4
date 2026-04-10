//+------------------------------------------------------------------+
//|                                      VSA_Reverse_ESS_v1_1.mq4   |
//|        VSA Reverse: Exhaustion Score System v1.1                  |
//|                                   Copyright © 2026, Ruslan Kuchma. |
//+------------------------------------------------------------------+
//| ТЕХНИЧЕСКОЕ ЗАДАНИЕ                                               |
//|                                                                   |
//| КОНЦЕПЦИЯ:                                                        |
//|   Стрелочный индикатор разворота по тиковому объёму.              |
//|   Детектирует кульминацию/истощение на конце серии из N+ баров    |
//|   одного направления через скоринговую систему из 5 условий.      |
//|                                                                   |
//| МЕТОДОЛОГИЯ (Exhaustion Score System):                            |
//|   1. Bar[1] (закрытый) — часть серии N+ баров одного направления |
//|   2. 5 условий истощения → ExhaustionScore (0..5)                |
//|      C1: Volume Spike — объём > K × среднего                     |
//|      C2: Body Shrinkage — тело сжалось vs предыдущего бара       |
//|      C3: Wick Rejection — хвост против направления               |
//|      C4: Volume Peak Passed — пик объёма уже позади              |
//|      C5: Distance Extended — серия покрыла > K × ATR              |
//|   3. Стрелка если Score >= MinScore (default 2)                  |
//|   4. Дедупликация: макс. 1 стрелка на серию                      |
//|                                                                   |
//| АНТИРЕПЕЙНТ:                                                      |
//|   Стрелка на bar[1]. Все данные из bar[1] и старше.              |
//|   Bar[0] НЕ используется. Стрелки НЕ исчезают и НЕ перемещаются.|
//|                                                                   |
//| БУФЕРЫ ДЛЯ EA (iCustom):                                         |
//|   Буфер 0 = BuyArrow (синяя стрелка вверх)                       |
//|   Буфер 1 = SellArrow (красная стрелка вниз)                     |
//|   Буфер 2 = ScoreRaw (0..5) — сила сигнала                      |
//|   Буфер 3 = SignalRaw (+1 BUY / -1 SELL / 0 нет)                |
//|                                                                   |
//| ПРИМЕР iCustom:                                                   |
//|   double sig = iCustom(NULL,0,"VSA_Reverse_ESS_v1_1",            |
//|                        2,2,20,1.3,0.75,0.50,14,1.0, ..., 3, 1); |
//|   if(sig > 0.5) → BUY; if(sig < -0.5) → SELL;                   |
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "1.10"
#property strict
#property description "VSA Reverse — Exhaustion Score System v1.1"
#property description "Стрелки разворота по тиковому объёму (bar[1])"
#property description "Buf2=Score(0..5), Buf3=Signal(+1/-1/0)"
#property description "Антирепейнт: bar[0] не используется"

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTIES                                                |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 4

#property indicator_label1  "BUY"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

#property indicator_label2  "SELL"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrCrimson
#property indicator_width2  2

#property indicator_label3  "Score"
#property indicator_type3   DRAW_NONE

#property indicator_label4  "Signal"
#property indicator_type4   DRAW_NONE

//+------------------------------------------------------------------+
//| БЛОК 2: ВХОДНЫЕ ПАРАМЕТРЫ                                         |
//+------------------------------------------------------------------+
input string   S0              = "=== ОСНОВНЫЕ ===";              // ═══════════════
input int      MinBars         = 1;                                // Мин. баров серии (2-5)
input int      MinScore        = 2;                                // Мин. Score для сигнала (1-5)
input int      Cooldown        = 5;                                // Мин. баров между стрелками одного типа

input string   S1              = "=== C1: Volume Spike ===";      // ═══════════════
input int      VolPeriod       = 14;                               // Период SMA объёма
input double   VolThreshold    = 1.5;                              // Порог VolRatio (×среднего)

input string   S2              = "=== C2: Body Shrinkage ===";    // ═══════════════
input double   ShrinkK         = 0.75;                             // Тело < ShrinkK × предыдущего

input string   S3              = "=== C3: Wick Rejection ===";    // ═══════════════
input double   WickK           = 0.50;                             // Хвост > WickK × Range

input string   S4              = "=== C5: Distance ===";          // ═══════════════
input int      ATR_Period      = 14;                               // Период ATR
input double   DistK           = 0.5;                              // Расстояние > DistK × ATR

input string   S5              = "=== ВИЗУАЛИЗАЦИЯ ===";          // ═══════════════
input int      ArrowOffset     = 20;                               // Отступ стрелки (пунктов)
input color    Color_Buy       = clrDodgerBlue;                    // Цвет BUY
input color    Color_Sell      = clrCrimson;                       // Цвет SELL
input int      ArrowSize       = 1;                                // Размер стрелки (1-5)

input string   S6              = "=== АЛЕРТЫ ===";                // ═══════════════
input bool     AlertOnSignal   = false;                            // Алерт при сигнале
input bool     UseSoundAlert   = false;                            // Звуковой алерт
input bool     UseEmailAlert   = false;                            // Email алерт
input bool     UsePushAlert    = false;                            // Push-уведомление

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                     |
//+------------------------------------------------------------------+
double BuyArrowBuf[];          // Буфер 0: BUY стрелки
double SellArrowBuf[];         // Буфер 1: SELL стрелки
double ScoreRawBuf[];          // Буфер 2: Score (0..5)
double SignalRawBuf[];         // Буфер 3: Signal (+1/-1/0)

// --- Валидированные параметры ---
int    g_minBars;
int    g_minScore;
int    g_cooldown;
int    g_volPeriod;
double g_volThreshold;
double g_shrinkK;
double g_wickK;
int    g_atrPeriod;
double g_distK;
double g_arrowOffset;

// --- Защита алертов ---
datetime g_lastAlertTime = 0;

//+------------------------------------------------------------------+
//| БЛОК 4: ИНИЦИАЛИЗАЦИЯ (OnInit)                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // ═══ Валидация ═══
   g_minBars      = MathMax(2, MathMin(MinBars, 10));
   g_minScore     = MathMax(1, MathMin(MinScore, 5));
   g_cooldown     = MathMax(0, MathMin(Cooldown, 20));
   g_volPeriod    = MathMax(5, MathMin(VolPeriod, 200));
   g_volThreshold = MathMax(1.0, MathMin(VolThreshold, 5.0));
   g_shrinkK      = MathMax(0.3, MathMin(ShrinkK, 0.95));
   g_wickK        = MathMax(0.2, MathMin(WickK, 0.9));
   g_atrPeriod    = MathMax(5, MathMin(ATR_Period, 200));
   g_distK        = MathMax(0.3, MathMin(DistK, 5.0));
   g_arrowOffset  = ArrowOffset * _Point;

   if(g_minBars != MinBars)       Print("⚠ MinBars скорректирован: ", g_minBars);
   if(g_minScore != MinScore)     Print("⚠ MinScore скорректирован: ", g_minScore);
   if(g_volPeriod != VolPeriod)   Print("⚠ VolPeriod скорректирован: ", g_volPeriod);

   // ═══ Буферы ═══
   SetIndexBuffer(0, BuyArrowBuf);
   SetIndexBuffer(1, SellArrowBuf);
   SetIndexBuffer(2, ScoreRawBuf);
   SetIndexBuffer(3, SignalRawBuf);

   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, ArrowSize, Color_Buy);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, ArrowSize, Color_Sell);
   SetIndexStyle(2, DRAW_NONE);
   SetIndexStyle(3, DRAW_NONE);

   SetIndexArrow(0, 233);   // Стрелка вверх
   SetIndexArrow(1, 234);   // Стрелка вниз

   SetIndexLabel(0, "BUY");
   SetIndexLabel(1, "SELL");
   SetIndexLabel(2, "Score");
   SetIndexLabel(3, "Signal");

   ArrayInitialize(BuyArrowBuf,  EMPTY_VALUE);
   ArrayInitialize(SellArrowBuf, EMPTY_VALUE);
   ArrayInitialize(ScoreRawBuf,  0.0);
   ArrayInitialize(SignalRawBuf, 0.0);

   IndicatorShortName("VSA_Rev(" + IntegerToString(g_minBars) + ","
                      + IntegerToString(g_minScore) + ")");
   IndicatorDigits(_Digits);

   Print("═══════════════════════════════════════════");
   Print("VSA Reverse ESS v1.1");
   Print("MinBars=", g_minBars, " MinScore=", g_minScore,
         " Cooldown=", g_cooldown);
   Print("C1: Vol>", DoubleToString(g_volThreshold, 1), "×avg(",
         g_volPeriod, ")");
   Print("C2: Body<", DoubleToString(g_shrinkK, 2), "×prev");
   Print("C3: Wick>", DoubleToString(g_wickK, 2), "×Range");
   Print("C4: VolPeak passed in sequence");
   Print("C5: Dist>", DoubleToString(g_distK, 1), "×ATR(",
         g_atrPeriod, ")");
   Print("Антирепейнт: стрелка на bar[1], bar[0] не используется");
   Print("═══════════════════════════════════════════");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 5: ОСНОВНОЙ РАСЧЁТ (OnCalculate)                              |
//+------------------------------------------------------------------+
//| ПРИНЦИП АНТИРЕПЕЙНТА:                                              |
//|   Стрелка ставится на bar[i] (i >= 1) по данным bar[i] и старше. |
//|   Bar[0] НИКОГДА не читается и не записывается.                   |
//|   После закрытия бара стрелка НЕ меняется и НЕ исчезает.         |
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
   // --- Минимум баров ---
   int minRequired = MathMax(g_volPeriod, g_atrPeriod) + g_minBars + 10;
   if(rates_total < minRequired)
      return(0);

   // --- Максимальная граница расчёта ---
   int maxLimit = rates_total - MathMax(g_volPeriod, g_atrPeriod) - 2;

   // --- Диапазон ---
   int limit;
   if(prev_calculated <= 0)
   {
      limit = maxLimit;
      ArrayInitialize(BuyArrowBuf,  EMPTY_VALUE);
      ArrayInitialize(SellArrowBuf, EMPTY_VALUE);
      ArrayInitialize(ScoreRawBuf,  0.0);
      ArrayInitialize(SignalRawBuf, 0.0);
   }
   else
   {
      // Пересчёт: bar[1] + запас для Cooldown проверки
      limit = rates_total - prev_calculated + g_cooldown + 1;
   }

   if(limit > maxLimit) limit = maxLimit;
   if(limit < 1)        limit = 1;

   // ═══════════════════════════════════════════════════════════════
   // ОСНОВНОЙ ЦИКЛ: от старых к новым, до bar[1] включительно
   // ═══════════════════════════════════════════════════════════════
   for(int i = limit; i >= 1; i--)
   {
      // --- Очистка текущего бара ---
      BuyArrowBuf[i]  = EMPTY_VALUE;
      SellArrowBuf[i] = EMPTY_VALUE;
      ScoreRawBuf[i]  = 0.0;
      SignalRawBuf[i] = 0.0;

      // ─── ШАГ 1: Направление bar[i] ───
      int barDir = GetBarDirection(open[i], close[i]);
      if(barDir == 0) continue;  // Доджи → пропуск

      // ─── ШАГ 2: Подсчёт серии назад от bar[i] ───
      // Считаем сколько подряд баров того же направления
      // идут от bar[i] в сторону истории
      int seqLen = 1;
      int seqStart = i;  // Самый старый бар серии (хронологически первый)

      for(int j = i + 1; j < rates_total - 1; j++)
      {
         int jDir = GetBarDirection(open[j], close[j]);
         if(jDir != barDir) break;
         seqLen++;
         seqStart = j;
      }

      if(seqLen < g_minBars) continue;

      // ─── ШАГ 3: Cooldown — защита от кластеров ───
      // Если в предыдущих g_cooldown барах уже есть стрелка
      // того же типа → пропуск (один сигнал на движение)
      if(g_cooldown > 0 && HasRecentArrow(i, barDir, g_cooldown))
         continue;

      // ─── ШАГ 4: РАСЧЁТ EXHAUSTION SCORE (5 условий) ───
      int score = 0;

      // ── C1: Volume Spike (кульминация объёма) ──
      // Текущий объём превышает среднее значение в K раз
      double avgVol = CalcSMA_Volume(tick_volume, i + 1, g_volPeriod, rates_total);
      double volRatio = (avgVol > 0.0) ? (double)tick_volume[i] / avgVol : 0.0;

      if(volRatio > g_volThreshold)
         score++;

      // ── C2: Body Shrinkage (угасание импульса) ──
      // Тело bar[i] меньше чем ShrinkK × тело bar[i+1]
      // = импульс выдыхается, хотя направление сохраняется
      double bodyI    = MathAbs(close[i] - open[i]);
      double bodyPrev = MathAbs(close[i + 1] - open[i + 1]);

      if(bodyPrev > _Point && bodyI < bodyPrev * g_shrinkK)
         score++;

      // ── C3: Wick Rejection (отвержение ценой) ──
      // Длинный хвост ПРОТИВ направления серии = цена отвергнута
      // Бычья серия: верхний хвост > WickK × Range → отвержение сверху
      // Медвежья серия: нижний хвост > WickK × Range → отвержение снизу
      double barRange = high[i] - low[i];
      if(barRange > _Point)
      {
         if(barDir == 1)
         {
            double upperWick = high[i] - MathMax(open[i], close[i]);
            if(upperWick > barRange * g_wickK)
               score++;
         }
         else
         {
            double lowerWick = MathMin(open[i], close[i]) - low[i];
            if(lowerWick > barRange * g_wickK)
               score++;
         }
      }

      // ── C4: Volume Peak Passed (пик объёма позади) ──
      // Максимальный объём серии был на более раннем баре,
      // текущий объём ниже максимума → пост-кульминация
      double maxVolInSeq = FindMaxVolume(tick_volume, i, seqStart, rates_total);

      if((double)tick_volume[i] < maxVolInSeq && maxVolInSeq > avgVol)
         score++;

      // ── C5: Distance Extended (серия прошла далеко) ──
      // Суммарное расстояние серии > DistK × ATR
      // Чем дальше уехала серия, тем вероятнее разворот
      double seqDist = MathAbs(close[i] - open[seqStart]);
      double atrVal  = iATR(NULL, 0, g_atrPeriod, i);
      if(atrVal < _Point * 10.0) atrVal = _Point * 10.0;

      if(seqDist > atrVal * g_distK)
         score++;

      // ─── ШАГ 5: Запись Score ───
      ScoreRawBuf[i] = (double)score;

      // ─── ШАГ 6: Стрелка при Score >= MinScore ───
      if(score < g_minScore) continue;

      if(barDir == 1)
      {
         // Бычья серия истощена → SELL
         SellArrowBuf[i] = high[i] + g_arrowOffset;
         SignalRawBuf[i] = -1.0;
      }
      else
      {
         // Медвежья серия истощена → BUY
         BuyArrowBuf[i] = low[i] - g_arrowOffset;
         SignalRawBuf[i] = 1.0;
      }
   }

   // ═══ Алерты ═══
   CheckAlerts(time);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| Направление бара: +1 бычий, -1 медвежий, 0 доджи                  |
//+------------------------------------------------------------------+
int GetBarDirection(double op, double cl)
{
   if(cl > op + _Point) return(1);
   if(cl < op - _Point) return(-1);
   return(0);
}

//+------------------------------------------------------------------+
//| SMA тикового объёма за period баров начиная с startBar            |
//| startBar = i+1 чтобы НЕ включать текущий бар в среднее           |
//+------------------------------------------------------------------+
double CalcSMA_Volume(const long &tv[], int startBar, int period, int total)
{
   double sum = 0.0;
   int cnt = 0;

   for(int j = startBar; j < startBar + period && j < total; j++)
   {
      sum += (double)tv[j];
      cnt++;
   }

   return(cnt > 0 ? sum / (double)cnt : 1.0);
}

//+------------------------------------------------------------------+
//| Макс. объём в серии от barI до seqStart включительно               |
//+------------------------------------------------------------------+
double FindMaxVolume(const long &tv[], int barI, int seqStart, int total)
{
   double maxVol = 0.0;
   for(int k = barI; k <= seqStart && k < total; k++)
   {
      if((double)tv[k] > maxVol)
         maxVol = (double)tv[k];
   }
   return(maxVol);
}

//+------------------------------------------------------------------+
//| Проверка: есть ли стрелка того же типа в предыдущих N барах       |
//| barDir=1 (бычья серия) → ищем SELL стрелки                        |
//| barDir=-1 (медвежья серия) → ищем BUY стрелки                     |
//+------------------------------------------------------------------+
bool HasRecentArrow(int barIndex, int barDir, int lookback)
{
   for(int j = barIndex + 1; j <= barIndex + lookback; j++)
   {
      if(barDir == 1 && SellArrowBuf[j] != EMPTY_VALUE)
         return(true);
      if(barDir == -1 && BuyArrowBuf[j] != EMPTY_VALUE)
         return(true);
   }
   return(false);
}

//+------------------------------------------------------------------+
//| Алерты на bar[1]                                                   |
//+------------------------------------------------------------------+
void CheckAlerts(const datetime &time[])
{
   if(!AlertOnSignal) return;
   if(SignalRawBuf[1] == 0.0) return;
   if(time[1] <= g_lastAlertTime) return;

   g_lastAlertTime = time[1];

   string dir = (SignalRawBuf[1] > 0) ? "BUY ↑" : "SELL ↓";
   int sc = (int)ScoreRawBuf[1];
   string msg = "VSA Reverse: " + dir + " | Score=" + IntegerToString(sc)
              + "/5 | " + _Symbol + " " + EnumToString((ENUM_TIMEFRAMES)_Period);

   Alert(msg);

   if(UseSoundAlert)  PlaySound("alert.wav");
   if(UseEmailAlert)  SendMail("VSA Reverse Signal", msg);
   if(UsePushAlert)   SendNotification(msg);
}

//+------------------------------------------------------------------+
//| БЛОК 7: OnDeinit                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("VSA Reverse ESS v1.1 деинициализирован. Код: ", reason);
}
//+------------------------------------------------------------------+
