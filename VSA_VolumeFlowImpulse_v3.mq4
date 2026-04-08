//+------------------------------------------------------------------+
//|                                  VSA_VolumeFlowImpulse_v3.mq4    |
//|        Volume Flow Impulse: кумулятивный объёмный импульс         |
//|                                   Copyright © 2026, Ruslan Kuchma |
//+------------------------------------------------------------------+
//| ВЕРСИЯ 3.0 — Гибрид подходов VWPM + VRI:                         |
//|   • IntraImpulse = (Close-Open)/ATR  — качество бара              |
//|   • InterImpulse = ΔClose/ATR        — факт движения цены         |
//|   • VolWeight = Vol/AvgVol           — объёмное подтверждение      |
//|   • Score = SMA(Impulse, N) × K      — кумулятивный, ±100         |
//|   • Антирепейнт: бар 0 НЕ рассчитывается                         |
//+------------------------------------------------------------------+
//| ИНТЕРПРЕТАЦИЯ:                                                    |
//|   Score > +50  = сильный бычий импульс с подтверждением объёмом   |
//|   Score > +25  = умеренный бычий импульс                          |
//|   Score −25..+25 = нет ясного импульса (флэт / неопределённость)  |
//|   Score < −25  = умеренный медвежий импульс                       |
//|   Score < −50  = сильный медвежий импульс с подтверждением объёмом|
//+------------------------------------------------------------------+
//| БУФЕРЫ ДЛЯ EA (iCustom):                                         |
//|   Буфер 0 = ScoreBull (гистограмма >0)                           |
//|   Буфер 1 = ScoreBear (гистограмма <0)                           |
//|   Буфер 2 = ScoreRaw  (−100..+100)                               |
//|   Буфер 3 = ImpulseRaw (сырой импульс бара, ~−1..+1)            |
//|   Буфер 4 = VolRatio  (объём / среднее, 0..VolCap)               |
//+------------------------------------------------------------------+
//| ПРИМЕР iCustom:                                                   |
//|   double score = iCustom(NULL,0,"VSA_VolumeFlowImpulse_v3",      |
//|                          14,14,10, 3.0,100.0,                    |
//|                          ..., 2, 1);   // buf=2, bar=1           |
//+------------------------------------------------------------------+
//| РЕКОМЕНДУЕМЫЕ НАСТРОЙКИ:                                          |
//|   D1:  ATR=14, Vol=14, Smooth=5,  Cap=3.0, K=150                |
//|   H4:  ATR=14, Vol=14, Smooth=8,  Cap=3.0, K=130                |
//|   H1:  ATR=20, Vol=20, Smooth=12, Cap=3.0, K=120                |
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "3.00"
#property strict
#property description "Volume Flow Impulse — кумулятивный объёмный осциллятор"
#property description "Buf2=Score, Buf3=Impulse, Buf4=VolRatio"
#property description "Антирепейнт: бар 0 не рассчитывается"

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTIES ПОДОКНА                                        |
//+------------------------------------------------------------------+
#property indicator_separate_window
#property indicator_buffers 5

// --- Буфер 0: гистограмма Score > 0 (бычий) ---
#property indicator_label1  "Score Bull"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrBlue
#property indicator_width1  3

// --- Буфер 1: гистограмма Score < 0 (медвежий) ---
#property indicator_label2  "Score Bear"
#property indicator_type2   DRAW_HISTOGRAM
#property indicator_color2  clrRed
#property indicator_width2  3

// --- Буфер 2: ScoreRaw для EA (скрытый) ---
#property indicator_label3  "ScoreRaw"
#property indicator_type3   DRAW_NONE

// --- Буфер 3: ImpulseRaw для EA (скрытый) ---
#property indicator_label4  "ImpulseRaw"
#property indicator_type4   DRAW_NONE

// --- Буфер 4: VolRatio для EA (скрытый) ---
#property indicator_label5  "VolRatio"
#property indicator_type5   DRAW_NONE

// --- Уровни по умолчанию (перезаписываются в OnInit) ---
#property indicator_level1   50.0
#property indicator_level2  -50.0
#property indicator_level3   0.0
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

//+------------------------------------------------------------------+
//| БЛОК 2: ВХОДНЫЕ ПАРАМЕТРЫ                                         |
//+------------------------------------------------------------------+
input string   S0              = "=== ОСНОВНЫЕ ===";              // ═══════════════
input int      ATR_Period      = 14;                               // Период ATR (5-200)
input int      VolSMA_Period   = 14;                               // Период SMA объёма (5-200)
input int      SmoothPeriod    = 5;                               // Период сглаживания SMA (3-50)
input double   VolumeCap       = 3.0;                              // Потолок объёма (×AvgVol, 1.5-10)
input double   ScaleK          = 150.0;                            // Масштаб Score (50-500)

input string   S1              = "=== УРОВНИ ===";                // ═══════════════
input double   UpperLevel      = 50.0;                             // Верхний уровень
input double   LowerLevel      = -50.0;                            // Нижний уровень
input color    LevelColor      = clrGray;                          // Цвет уровней
input int      LevelWidth      = 1;                                // Толщина уровней (1-5)
input ENUM_LINE_STYLE LevelStyle = STYLE_DOT;                      // Стиль уровней

input string   S2              = "=== ЦВЕТА И СТИЛЬ ===";         // ═══════════════
input color    Color_Bull      = clrBlue;                          // Бычья гистограмма
input color    Color_Bear      = clrRed;                           // Медвежья гистограмма
input int      Width_Hist      = 3;                                // Толщина гистограммы (1-5)

input string   S3              = "=== АЛЕРТЫ ===";                // ═══════════════
input bool     AlertOnStrong   = false;                            // Алерт при |Score| > UpperLevel
input bool     UseSoundAlert   = false;                            // Звуковой алерт
input bool     UseEmailAlert   = false;                            // Email алерт
input bool     UsePushAlert    = false;                            // Push-уведомление

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И БУФЕРЫ                            |
//+------------------------------------------------------------------+

// --- Визуальные буферы ---
double ScoreBullBuf[];       // Буфер 0: гистограмма Score > 0 (синий)
double ScoreBearBuf[];       // Буфер 1: гистограмма Score < 0 (красный)

// --- Служебные буферы для EA (iCustom) ---
double ScoreRawBuf[];        // Буфер 2: Score (−100..+100)
double ImpulseRawBuf[];      // Буфер 3: сырой Impulse бара (~−1..+1)
double VolRatioBuf[];        // Буфер 4: Vol / AvgVol (0..VolCap)

// --- Защита алертов ---
datetime LastAlertTime = 0;

// --- Валидированные параметры ---
int    g_atr_period;
int    g_vol_period;
int    g_smooth_period;
double g_volume_cap;
double g_scale_k;

//+------------------------------------------------------------------+
//| БЛОК 4: ИНИЦИАЛИЗАЦИЯ (OnInit)                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // ═══════════════════════════════════════════
   // Валидация входных параметров
   // ═══════════════════════════════════════════
   g_atr_period = ATR_Period;
   if(g_atr_period < 5)   { g_atr_period = 14;  Print("⚠ ATR_Period < 5, установлено 14"); }
   if(g_atr_period > 200) { g_atr_period = 200; Print("⚠ ATR_Period > 200, установлено 200"); }

   g_vol_period = VolSMA_Period;
   if(g_vol_period < 5)   { g_vol_period = 14;  Print("⚠ VolSMA_Period < 5, установлено 14"); }
   if(g_vol_period > 200) { g_vol_period = 200; Print("⚠ VolSMA_Period > 200, установлено 200"); }

   g_smooth_period = SmoothPeriod;
   if(g_smooth_period < 3)  { g_smooth_period = 10; Print("⚠ SmoothPeriod < 3, установлено 10"); }
   if(g_smooth_period > 50) { g_smooth_period = 50; Print("⚠ SmoothPeriod > 50, установлено 50"); }

   g_volume_cap = VolumeCap;
   if(g_volume_cap < 1.5)  { g_volume_cap = 3.0;  Print("⚠ VolumeCap < 1.5, установлено 3.0"); }
   if(g_volume_cap > 10.0) { g_volume_cap = 10.0; Print("⚠ VolumeCap > 10.0, установлено 10.0"); }

   g_scale_k = ScaleK;
   if(g_scale_k < 50.0)  { g_scale_k = 100.0; Print("⚠ ScaleK < 50, установлено 100"); }
   if(g_scale_k > 500.0) { g_scale_k = 500.0; Print("⚠ ScaleK > 500, установлено 500"); }

   // ═══════════════════════════════════════════
   // Привязка буферов
   // ═══════════════════════════════════════════
   SetIndexBuffer(0, ScoreBullBuf);
   SetIndexBuffer(1, ScoreBearBuf);
   SetIndexBuffer(2, ScoreRawBuf);
   SetIndexBuffer(3, ImpulseRawBuf);
   SetIndexBuffer(4, VolRatioBuf);

   // ═══════════════════════════════════════════
   // Стили визуальных буферов
   // ═══════════════════════════════════════════
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, Width_Hist, Color_Bull);
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, Width_Hist, Color_Bear);
   SetIndexStyle(2, DRAW_NONE);
   SetIndexStyle(3, DRAW_NONE);
   SetIndexStyle(4, DRAW_NONE);

   // ═══════════════════════════════════════════
   // Метки буферов
   // ═══════════════════════════════════════════
   SetIndexLabel(0, "Score Bull");
   SetIndexLabel(1, "Score Bear");
   SetIndexLabel(2, "ScoreRaw");
   SetIndexLabel(3, "ImpulseRaw");
   SetIndexLabel(4, "VolRatio");

   // ═══════════════════════════════════════════
   // Инициализация буферов
   // ═══════════════════════════════════════════
   ArrayInitialize(ScoreBullBuf,  0.0);
   ArrayInitialize(ScoreBearBuf,  0.0);
   ArrayInitialize(ScoreRawBuf,   EMPTY_VALUE);
   ArrayInitialize(ImpulseRawBuf, EMPTY_VALUE);
   ArrayInitialize(VolRatioBuf,   EMPTY_VALUE);

   // ═══════════════════════════════════════════
   // Настраиваемые уровни
   // ═══════════════════════════════════════════
   IndicatorSetInteger(INDICATOR_LEVELS, 3);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, UpperLevel);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, LowerLevel);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, 0.0);
   for(int lv = 0; lv < 3; lv++)
   {
      IndicatorSetInteger(INDICATOR_LEVELCOLOR, lv, (int)LevelColor);
      IndicatorSetInteger(INDICATOR_LEVELSTYLE, lv, (int)LevelStyle);
      IndicatorSetInteger(INDICATOR_LEVELWIDTH, lv, LevelWidth);
   }

   // ═══════════════════════════════════════════
   // Название и точность
   // ═══════════════════════════════════════════
   IndicatorShortName("VFI(" + IntegerToString(g_atr_period) + ","
                      + IntegerToString(g_vol_period) + ","
                      + IntegerToString(g_smooth_period) + ")");
   IndicatorDigits(1);

   // --- Лог инициализации ---
   Print("═══════════════════════════════════════════");
   Print("VSA VolumeFlowImpulse v3.0");
   Print("ATR=", g_atr_period, " VolSMA=", g_vol_period,
         " Smooth=", g_smooth_period,
         " Cap=", DoubleToString(g_volume_cap, 1),
         " K=", DoubleToString(g_scale_k, 0));
   Print("Формула: SMA[(Intra+Inter)/2 × VolWeight, ", g_smooth_period, "] × ", DoubleToString(g_scale_k, 0));
   Print("Репейнт: ОТСУТСТВУЕТ (бар 0 не рассчитывается)");
   Print("═══════════════════════════════════════════");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 5: ДЕИНИЦИАЛИЗАЦИЯ (OnDeinit)                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("VFI v3.0 деинициализирован. Код: ", reason);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ОСНОВНОЙ РАСЧЁТ (OnCalculate)                              |
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
   // --- Минимум баров для корректного расчёта ---
   // ATR нужен g_atr_period баров, SMA объёма g_vol_period,
   // сглаживание g_smooth_period, + запас
   int maxPeriod = MathMax(g_atr_period, g_vol_period);
   int minBars   = maxPeriod + g_smooth_period + 10;
   if(rates_total < minBars)
      return(0);

   // --- Определение диапазона расчёта ---
   int limit;
   if(prev_calculated <= 0)
   {
      // Первый запуск: считаем от самого старого доступного бара
      // Нужен запас: maxPeriod для ATR/VolSMA + 1 для InterImpulse
      limit = rates_total - maxPeriod - 2;

      // Чистый старт
      ArrayInitialize(ScoreBullBuf,  0.0);
      ArrayInitialize(ScoreBearBuf,  0.0);
      ArrayInitialize(ScoreRawBuf,   EMPTY_VALUE);
      ArrayInitialize(ImpulseRawBuf, EMPTY_VALUE);
      ArrayInitialize(VolRatioBuf,   EMPTY_VALUE);
   }
   else
   {
      // Инкрементальный: пересчёт новых баров + запас сглаживания
      limit = rates_total - prev_calculated + g_smooth_period;
   }

   // --- Защита верхней границы ---
   if(limit > rates_total - maxPeriod - 2)
      limit = rates_total - maxPeriod - 2;

   // --- Антирепейнт: бар 0 НЕ считается ---
   if(limit < 1)
      limit = 1;

   // =================================================================
   // ПРОХОД 1: Расчёт сырого импульса каждого бара (ImpulseRaw)
   // =================================================================
   for(int i = limit; i >= 1; i--)
   {
      // ─── 1. ATR (кешируется терминалом MT4) ───
      double atr = iATR(NULL, 0, g_atr_period, i);
      if(atr < _Point * 10.0)
         atr = _Point * 10.0;   // Защита от нулевого ATR

      // ─── 2. Тиковый объём ───
      double vol = (double)tick_volume[i];
      if(vol < 1.0) vol = 1.0;

      // ─── 3. Средний объём за g_vol_period баров ───
      double avgVol = CalcAvgVolume(tick_volume, i, g_vol_period, rates_total);
      if(avgVol < 1.0) avgVol = 1.0;

      // ─── 4. VolWeight: нормализованный объём (0..1) ───
      // vol/avgVol = 1.0 → средний объём
      // vol/avgVol = 3.0 → максимум при VolCap=3.0
      double volRatio = vol / avgVol;
      double volWeight = MathMin(volRatio, g_volume_cap) / g_volume_cap;  // 0..1

      // ─── 5. IntraImpulse: качество бара ───
      // (Close - Open) / ATR — размер и направление тела
      // Положительный = бычий бар, отрицательный = медвежий
      double intraImpulse = (close[i] - open[i]) / atr;

      // ─── 6. InterImpulse: факт движения цены ───
      // (Close[i] - Close[i+1]) / ATR — межбаровое изменение
      // Ловит гэпы и движения, которые Body не видит
      double interImpulse = 0.0;
      int prevBar = i + 1;
      if(prevBar < rates_total)
         interImpulse = (close[i] - close[prevBar]) / atr;

      // ─── 7. ГИБРИДНЫЙ ИМПУЛЬС ───
      // Среднее Intra и Inter × объёмный вес
      // Оба компонента дополняют друг друга:
      //   - Intra = качество текущего бара
      //   - Inter = реальное смещение цены
      //   - VolWeight = подтверждение деньгами
      double impulse = (intraImpulse + interImpulse) * 0.5 * volWeight;

      // ─── 8. Запись в служебные буферы ───
      ImpulseRawBuf[i] = impulse;
      VolRatioBuf[i]   = volRatio;
   }

   // =================================================================
   // ПРОХОД 2: Сглаживание SMA → Score (−100..+100) и гистограмма
   // =================================================================
   for(int i = limit; i >= 1; i--)
   {
      // --- SMA(Impulse, SmoothPeriod) ---
      double score = CalcScoreSMA(i, g_smooth_period, rates_total);

      // --- Масштабирование и clamp ---
      score *= g_scale_k;
      if(score > 100.0)  score = 100.0;
      if(score < -100.0) score = -100.0;

      // --- Запись Score в буфер для EA ---
      ScoreRawBuf[i] = score;

      // --- Цветная гистограмма ---
      if(score > 0.0)
      {
         ScoreBullBuf[i] = score;
         ScoreBearBuf[i] = 0.0;
      }
      else
      {
         ScoreBullBuf[i] = 0.0;
         ScoreBearBuf[i] = score;
      }
   }

   // =================================================================
   // АЛЕРТЫ (только на закрытом баре [1])
   // =================================================================
   CheckAlerts(time);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                    |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| SMA тикового объёма за period баров начиная с barIndex            |
//| Возвращает среднее значение tick_volume за окно                   |
//+------------------------------------------------------------------+
double CalcAvgVolume(const long &tick_vol[],
                     int barIndex,
                     int period,
                     int total)
{
   double sum = 0.0;
   int count  = 0;

   for(int k = 0; k < period; k++)
   {
      int idx = barIndex + k;   // barIndex + k = более старый бар
      if(idx >= total)
         break;

      double v = (double)tick_vol[idx];
      if(v < 1.0) v = 1.0;     // Защита от нулевого объёма
      sum += v;
      count++;
   }

   if(count <= 0)
      return(1.0);

   return(sum / (double)count);
}

//+------------------------------------------------------------------+
//| SMA от ImpulseRawBuf за smoothPeriod баров от barIndex            |
//| Возвращает среднее значение импульса (кумулятивный эффект)        |
//+------------------------------------------------------------------+
double CalcScoreSMA(int barIndex, int smoothPeriod, int total)
{
   double sum = 0.0;
   int count  = 0;

   for(int k = 0; k < smoothPeriod; k++)
   {
      int idx = barIndex + k;   // barIndex + k = более старый бар
      if(idx >= total)
         break;

      // Пропуск незаполненных баров
      if(ImpulseRawBuf[idx] == EMPTY_VALUE ||
         ImpulseRawBuf[idx] >= DBL_MAX - 1.0)
         continue;

      sum += ImpulseRawBuf[idx];
      count++;
   }

   // Если недостаточно данных — возвращаем 0
   if(count < 2)
      return(0.0);

   return(sum / (double)count);
}

//+------------------------------------------------------------------+
//| Проверка алертов на баре [1]                                      |
//+------------------------------------------------------------------+
void CheckAlerts(const datetime &time[])
{
   // --- Алерты отключены ---
   if(!AlertOnStrong)
      return;

   // --- Один алерт на бар ---
   if(LastAlertTime == time[1])
      return;

   // --- Проверка Score на баре [1] ---
   if(ScoreRawBuf[1] == EMPTY_VALUE || ScoreRawBuf[1] >= DBL_MAX - 1.0)
      return;

   double score = ScoreRawBuf[1];
   string msg = "";

   if(score >= UpperLevel)
      msg = "STRONG BUY: Score=" + DoubleToString(score, 1);
   else if(score <= LowerLevel)
      msg = "STRONG SELL: Score=" + DoubleToString(score, 1);

   if(msg == "")
      return;

   // --- Формирование и отправка ---
   string fullMsg = "VFI [" + _Symbol + " " + GetTFName() + "]: " + msg;

   if(UseSoundAlert)
      PlaySound("alert.wav");

   Alert(fullMsg);

   if(UseEmailAlert)
      SendMail("VFI Alert", fullMsg);

   if(UsePushAlert)
      SendNotification(fullMsg);

   LastAlertTime = time[1];
}

//+------------------------------------------------------------------+
//| Название таймфрейма для алертов                                    |
//+------------------------------------------------------------------+
string GetTFName()
{
   switch(_Period)
   {
      case PERIOD_M1:  return("M1");
      case PERIOD_M5:  return("M5");
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN");
      default:         return("TF" + IntegerToString(_Period));
   }
}

//+------------------------------------------------------------------+
//| БЛОК 8: КОНЕЦ ФАЙЛА                                                |
//+------------------------------------------------------------------+
