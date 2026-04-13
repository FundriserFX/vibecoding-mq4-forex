//+------------------------------------------------------------------+
//|                                      VSA_Reverse_ESS_v2_0.mq4   |
//|        VSA Reverse: Exhaustion Score System v2.0                  |
//|                                   Copyright © 2026, Ruslan Kuchma |
//+------------------------------------------------------------------+
//| ТЕХНИЧЕСКОЕ ЗАДАНИЕ                                               |
//|                                                                   |
//| КОНЦЕПЦИЯ:                                                        |
//|   Стрелочный индикатор разворота на базе OHLC + tick_volume.      |
//|   Детектирует истощение на конце серии из N+ баров одного          |
//|   направления через взвешенную скоринговую систему из 4 условий.  |
//|                                                                   |
//| МЕТОДОЛОГИЯ (ESS v2.0 — 4 ортогональных критерия):               |
//|   1. Bar[1] (закрытый) — часть серии N+ баров одного направления |
//|   2. 4 условия истощения → ExhaustionScore (0.0..6.5)            |
//|      C1: Wick Rejection — хвост ПРОТИВ направления серии (max 2.0)|
//|      C2: ROC Decay — замедление Close-to-Close (max 2.0)        |
//|      C3: Range Compression — сжатие диапазона бара (max 1.5)     |
//|      C4: Volume Climax — всплеск тикового объёма (max 1.0)       |
//|   3. Стрелка если Score >= MinScore (default 3.0)                |
//|   4. Дедупликация: Cooldown между стрелками одного типа          |
//|                                                                   |
//| ОТЛИЧИЯ ОТ v1.1:                                                  |
//|   - Удалены "бесплатные" критерии (VolumePeakPassed, Distance)   |
//|   - Добавлен ROC Decay (опережающий сигнал затухания)            |
//|   - Добавлен Range Compression (энергия покидает рынок)          |
//|   - Взвешенный скоринг вместо бинарного (0/1 → 0.0..2.0)        |
//|   - 4 критерия на 3 независимых осях (бар/серия/объём)           |
//|                                                                   |
//| АНТИРЕПЕЙНТ:                                                      |
//|   Стрелка на bar[1]. Все данные из bar[1] и старше.              |
//|   Bar[0] НЕ используется. Стрелки НЕ исчезают и НЕ перемещаются.|
//|                                                                   |
//| БУФЕРЫ ДЛЯ EA (iCustom):                                         |
//|   Буфер 0 = BuyArrow (синяя стрелка вверх)                       |
//|   Буфер 1 = SellArrow (красная стрелка вниз)                     |
//|   Буфер 2 = ScoreRaw (0.0..6.5) — сила сигнала                  |
//|   Буфер 3 = SignalRaw (+1 BUY / -1 SELL / 0 нет)                |
//|                                                                   |
//| ПРИМЕР iCustom:                                                   |
//|   double sig = iCustom(NULL,0,"VSA_Reverse_ESS_v2_0",            |
//|                        2,3.0,5,0.45,0.65,20,1.8, ..., 3, 1);    |
//|   if(sig > 0.5) → BUY; if(sig < -0.5) → SELL;                   |
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "2.00"
#property strict
#property description "VSA Reverse — Exhaustion Score System v2.0"
#property description "4 критерия: Wick|ROC|Range|Volume (bar[1])"
#property description "Buf2=Score(0..6.5), Buf3=Signal(+1/-1/0)"
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
input int      MinBars         = 2;                                // Мин. баров серии (2-10)
input double   MinScore        = 3.0;                              // Мин. Score для сигнала (1.0-6.5)
input int      Cooldown        = 5;                                // Мин. баров между стрелками одного типа

input string   S1              = "=== C1: Wick Rejection ===";    // ═══════════════
input double   WickK           = 0.45;                             // Хвост > WickK × Range → +1.0 (0.20-0.90)
input double   WickK_Strong    = 0.60;                             // Хвост > WickK_Strong × Range → +2.0

input string   S2              = "=== C2: ROC Decay ===";         // ═══════════════
// Нет параметров — работает автоматически по Close-to-Close серии

input string   S3              = "=== C3: Range Compression ==="; // ═══════════════
input double   RangeK          = 0.65;                             // Range < RangeK × AvgRange серии → +0.75
input double   RangeK_Strong   = 0.45;                             // Range < RangeK_Strong → +1.5

input string   S4              = "=== C4: Volume Climax ===";     // ═══════════════
input int      VolPeriod       = 20;                               // Период SMA объёма
input double   VolThreshold    = 1.8;                              // Объём > VolThreshold × среднего → +1.0

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
double ScoreRawBuf[];          // Буфер 2: Score (0.0..6.5)
double SignalRawBuf[];         // Буфер 3: Signal (+1/-1/0)

// --- Валидированные параметры ---
int    g_minBars;              // мин. длина серии
double g_minScore;             // порог Score для стрелки
int    g_cooldown;             // мин. баров между стрелками
double g_wickK;                // порог хвоста (стандартный)
double g_wickK_strong;         // порог хвоста (сильный)
double g_rangeK;               // порог сжатия (стандартный)
double g_rangeK_strong;        // порог сжатия (сильный)
int    g_volPeriod;            // период SMA объёма
double g_volThreshold;         // порог объёма
double g_arrowOffset;          // отступ стрелки в ценовых единицах

// --- Защита алертов ---
datetime g_lastAlertTime = 0;

//+------------------------------------------------------------------+
//| БЛОК 4: ИНИЦИАЛИЗАЦИЯ (OnInit)                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // ═══ Валидация входных параметров ═══
   g_minBars       = MathMax(2, MathMin(MinBars, 10));
   g_minScore      = MathMax(1.0, MathMin(MinScore, 6.5));
   g_cooldown      = MathMax(0, MathMin(Cooldown, 30));
   g_wickK         = MathMax(0.20, MathMin(WickK, 0.90));
   g_wickK_strong  = MathMax(g_wickK + 0.05, MathMin(WickK_Strong, 0.95));
   g_rangeK        = MathMax(0.30, MathMin(RangeK, 0.90));
   g_rangeK_strong = MathMax(0.15, MathMin(RangeK_Strong, g_rangeK - 0.05));
   g_volPeriod     = MathMax(5, MathMin(VolPeriod, 200));
   g_volThreshold  = MathMax(1.2, MathMin(VolThreshold, 5.0));
   g_arrowOffset   = ArrowOffset * _Point;

   // --- Логирование коррекций ---
   if(g_minBars != MinBars)
      Print("⚠ MinBars скорректирован: ", g_minBars);
   if(NormalizeDouble(g_minScore - MinScore, 2) != 0.0)
      Print("⚠ MinScore скорректирован: ", DoubleToString(g_minScore, 1));
   if(g_wickK_strong <= g_wickK)
   {
      g_wickK_strong = g_wickK + 0.10;
      Print("⚠ WickK_Strong скорректирован: ", DoubleToString(g_wickK_strong, 2));
   }
   if(g_rangeK_strong >= g_rangeK)
   {
      g_rangeK_strong = g_rangeK - 0.15;
      Print("⚠ RangeK_Strong скорректирован: ", DoubleToString(g_rangeK_strong, 2));
   }

   // ═══ Буферы ═══
   SetIndexBuffer(0, BuyArrowBuf);
   SetIndexBuffer(1, SellArrowBuf);
   SetIndexBuffer(2, ScoreRawBuf);
   SetIndexBuffer(3, SignalRawBuf);

   SetIndexStyle(0, DRAW_ARROW, STYLE_SOLID, ArrowSize, Color_Buy);
   SetIndexStyle(1, DRAW_ARROW, STYLE_SOLID, ArrowSize, Color_Sell);
   SetIndexStyle(2, DRAW_NONE);
   SetIndexStyle(3, DRAW_NONE);

   SetIndexArrow(0, 233);   // стрелка вверх
   SetIndexArrow(1, 234);   // стрелка вниз

   SetIndexLabel(0, "BUY");
   SetIndexLabel(1, "SELL");
   SetIndexLabel(2, "Score");
   SetIndexLabel(3, "Signal");

   ArrayInitialize(BuyArrowBuf,  EMPTY_VALUE);
   ArrayInitialize(SellArrowBuf, EMPTY_VALUE);
   ArrayInitialize(ScoreRawBuf,  0.0);
   ArrayInitialize(SignalRawBuf, 0.0);

   IndicatorShortName("VSA_Rev2(" + IntegerToString(g_minBars) + ","
                      + DoubleToString(g_minScore, 1) + ")");
   IndicatorDigits(_Digits);

   // --- Лог параметров ---
   Print("═══════════════════════════════════════════");
   Print("VSA Reverse ESS v2.0 — 4 критерия");
   Print("MinBars=", g_minBars,
         " MinScore=", DoubleToString(g_minScore, 1),
         " Cooldown=", g_cooldown);
   Print("C1 Wick: >", DoubleToString(g_wickK, 2),
         "→+1.0, >", DoubleToString(g_wickK_strong, 2), "→+2.0");
   Print("C2 ROC Decay: auto (seqLen>=3)");
   Print("C3 Range: <", DoubleToString(g_rangeK, 2),
         "→+0.75, <", DoubleToString(g_rangeK_strong, 2), "→+1.5");
   Print("C4 Vol: >", DoubleToString(g_volThreshold, 1),
         "×avg(", g_volPeriod, ")→+1.0");
   Print("Антирепейнт: bar[1], bar[0] не используется");
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
   // --- Минимум баров для расчёта ---
   int minRequired = g_volPeriod + g_minBars + 10;
   if(rates_total < minRequired)
      return(0);

   // --- Верхняя граница расчёта ---
   int maxLimit = rates_total - g_volPeriod - 2;

   // --- Диапазон пересчёта ---
   int limit;
   if(prev_calculated <= 0)
   {
      // первый запуск — считаем всю историю
      limit = maxLimit;
      ArrayInitialize(BuyArrowBuf,  EMPTY_VALUE);
      ArrayInitialize(SellArrowBuf, EMPTY_VALUE);
      ArrayInitialize(ScoreRawBuf,  0.0);
      ArrayInitialize(SignalRawBuf, 0.0);
   }
   else
   {
      // обновление — пересчёт bar[1] + запас для Cooldown
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
      if(barDir == 0) continue;  // доджи → пропуск

      // ─── ШАГ 2: Подсчёт серии назад от bar[i] ───
      // серия = подряд идущие бары того же направления
      int seqLen   = 1;
      int seqStart = i;  // самый старый бар серии (хронологически первый)

      for(int j = i + 1; j < rates_total - 1; j++)
      {
         int jDir = GetBarDirection(open[j], close[j]);
         if(jDir != barDir) break;
         seqLen++;
         seqStart = j;
      }

      // серия короче минимума → пропуск
      if(seqLen < g_minBars) continue;

      // ─── ШАГ 3: Cooldown — защита от кластеров ───
      if(g_cooldown > 0 && HasRecentArrow(i, barDir, g_cooldown))
         continue;

      // ─── ШАГ 4: РАСЧЁТ EXHAUSTION SCORE (4 критерия) ───
      double score = 0.0;
      double barRange = high[i] - low[i];

      // ══════════════════════════════════════════════════════
      // C1: WICK REJECTION (max 2.0) — ось "Анатомия бара"
      // ══════════════════════════════════════════════════════
      // Хвост ПРОТИВ направления серии = цена отвергнута
      // Бычья серия → верхний хвост (покупатели не удержали)
      // Медвежья серия → нижний хвост (продавцы не удержали)
      if(barRange > _Point)
      {
         double wick = 0.0;

         if(barDir == 1)
            wick = high[i] - MathMax(open[i], close[i]);  // верхний хвост
         else
            wick = MathMin(open[i], close[i]) - low[i];   // нижний хвост

         double wickRatio = wick / barRange;

         if(wickRatio > g_wickK_strong)
            score += 2.0;       // доминирующий хвост → сильный сигнал
         else if(wickRatio > g_wickK)
            score += 1.0;       // заметный хвост → умеренный сигнал
      }

      // ══════════════════════════════════════════════════════
      // C2: ROC DECAY (max 2.0) — ось "Динамика серии"
      // ══════════════════════════════════════════════════════
      // Если каждый следующий бар серии проходит меньше
      // предыдущего (Close-to-Close), импульс затухает.
      // Это ОПЕРЕЖАЮЩИЙ сигнал: ловит затухание ещё когда
      // свечи одного цвета и визуально "всё нормально".
      if(seqLen >= 3)
      {
         // расстояние, пройденное каждым баром серии
         double roc1 = MathAbs(close[i]   - close[i+1]);  // последний бар
         double roc2 = MathAbs(close[i+1] - close[i+2]);  // предпоследний

         if(seqLen >= 4 && (i + 3) < rates_total)
         {
            // тройное замедление (3 последних бара)
            double roc3 = MathAbs(close[i+2] - close[i+3]);

            // защита от деления на 0: roc2 и roc3 > минимума
            if(roc3 > _Point && roc2 > _Point)
            {
               if(roc1 < roc2 && roc2 < roc3)
                  score += 2.0;    // убывающая последовательность → сильный
               else if(roc1 < roc2)
                  score += 1.0;    // одинарное замедление → умеренный
            }
            else if(roc2 > _Point && roc1 < roc2)
            {
               score += 1.0;
            }
         }
         else
         {
            // серия 3 бара — только одинарная проверка
            if(roc2 > _Point && roc1 < roc2)
               score += 1.5;       // замедление на короткой серии
         }
      }

      // ══════════════════════════════════════════════════════
      // C3: RANGE COMPRESSION (max 1.5) — ось "Анатомия бара"
      // ══════════════════════════════════════════════════════
      // Если диапазон текущего бара значительно меньше среднего
      // диапазона серии — энергия покинула рынок.
      // Ловит паттерн "тихой смерти" тренда.
      if(seqLen >= 2 && barRange > 0.0)
      {
         // средний диапазон серии БЕЗ текущего бара
         double sumRange = 0.0;
         int    cntRange = 0;

         for(int k = i + 1; k <= seqStart && k < rates_total; k++)
         {
            sumRange += high[k] - low[k];
            cntRange++;
         }

         if(cntRange > 0)
         {
            double avgRange = sumRange / (double)cntRange;

            if(avgRange > _Point)
            {
               double rangeRatio = barRange / avgRange;

               if(rangeRatio < g_rangeK_strong)
                  score += 1.5;    // сильное сжатие → максимальный балл
               else if(rangeRatio < g_rangeK)
                  score += 0.75;   // умеренное сжатие
            }
         }
      }

      // ══════════════════════════════════════════════════════
      // C4: VOLUME CLIMAX (max 1.0) — ось "Объём"
      // ══════════════════════════════════════════════════════
      // Тиковый объём текущего бара > K × среднему объёму.
      // Подтверждающий критерий: кульминация объёма = крупный
      // игрок зафиксировал позицию, импульс исчерпан.
      double avgVol = CalcSMA_Volume(tick_volume, i + 1, g_volPeriod, rates_total);
      if(avgVol > 0.0)
      {
         double volRatio = (double)tick_volume[i] / avgVol;
         if(volRatio > g_volThreshold)
            score += 1.0;
      }

      // ─── ШАГ 5: Запись Score ───
      ScoreRawBuf[i] = score;

      // ─── ШАГ 6: Стрелка при Score >= MinScore ───
      if(score < g_minScore) continue;

      if(barDir == 1)
      {
         // бычья серия истощена → SELL сигнал
         SellArrowBuf[i] = high[i] + g_arrowOffset;
         SignalRawBuf[i] = -1.0;
      }
      else
      {
         // медвежья серия истощена → BUY сигнал
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
   if(cl > op + _Point) return(1);   // бычий
   if(cl < op - _Point) return(-1);  // медвежий
   return(0);                         // доджи
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
   string msg = "VSA Rev2: " + dir
              + " | Score=" + DoubleToString(ScoreRawBuf[1], 1)
              + "/6.5 | " + _Symbol
              + " " + EnumToString((ENUM_TIMEFRAMES)_Period);

   Alert(msg);

   if(UseSoundAlert)  PlaySound("alert.wav");
   if(UseEmailAlert)  SendMail("VSA Reverse v2.0", msg);
   if(UsePushAlert)   SendNotification(msg);
}

//+------------------------------------------------------------------+
//| БЛОК 7: OnDeinit                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("VSA Reverse ESS v2.0 деинициализирован. Код: ", reason);
}
//+------------------------------------------------------------------+
