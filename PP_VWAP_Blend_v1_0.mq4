//+------------------------------------------------------------------+
//|                                       PP_VWAP_Blend_v1_0.mq4     |
//|   Pivot Point + VWAP Blend: сглаженная 3-дневная средняя линия   |
//|                                   Copyright © 2026, Ruslan Kuchma |
//+------------------------------------------------------------------+
//| ТЕХНИЧЕСКОЕ ЗАДАНИЕ:                                              |
//|                                                                   |
//| КОНЦЕПЦИЯ:                                                        |
//|   Классический Pivot Point (H+L+C)/3 — статическая точка, висит  |
//|   мёртвым грузом внутри дня и плохо показывает тренд во флэте.   |
//|   VWAP — объёмно-взвешенная цена, учитывает где реально прошли   |
//|   сделки, но не имеет "якоря" (уровня справедливой цены).        |
//|   ЭТОТ индикатор смешивает оба подхода:                           |
//|   • PP3D даёт якорь (классический 3-дневный уровень)              |
//|   • VWAP3D даёт динамику и наклон (объёмную правду)              |
//|   Результат — плавная линия, которая "дышит" с объёмом и         |
//|   реагирует на распределение сделок внутри 3-дневного окна.      |
//|                                                                   |
//| ФОРМУЛА:                                                          |
//|   H3 = max(High) за 3 завершённых D1-бара                         |
//|   L3 = min(Low)  за 3 завершённых D1-бара                         |
//|   C3 = Close последнего завершённого D1-бара                      |
//|   PP3D = (H3 + L3 + C3) / 3                                       |
//|   R1   = 2·PP3D − L3                                              |
//|   S1   = 2·PP3D − H3                                              |
//|   TP[k] = (High[k]+Low[k]+Close[k]) / 3  (на текущем TF)          |
//|   V[k]  = tick_volume[k]                                          |
//|   VWAP3D[i] = Σ(TP[k]·V[k]) / Σ(V[k])  для k = i..i+N−1,          |
//|                 где N = число баров за 3 суток на текущем TF     |
//|   Middle[i] = Alpha·PP3D + (1−Alpha)·VWAP3D[i],  Alpha=0.3        |
//|                                                                   |
//| ОКРАСКА:                                                          |
//|   Middle[i] > Middle[i+1] → СИНЯЯ (бычий наклон, BullLine)        |
//|   Middle[i] < Middle[i+1] → КРАСНАЯ (медвежий наклон, BearLine)   |
//|   Middle[i] == Middle[i+1] → сохраняется прошлый цвет             |
//|   На переходе цвета делается связка (обе линии на соседнем баре). |
//|                                                                   |
//| АНТИРЕПЕЙНТ (тройная защита):                                     |
//|   1) Цикл i >= 1 — бар[0] НЕ рассчитывается                       |
//|   2) D1-бары: всегда берутся 3 ЗАВЕРШЁННЫХ дня (d_shift+1 и далее)|
//|   3) Явный EMPTY_VALUE на баре 0 после цикла                     |
//|                                                                   |
//| БУФЕРЫ ДЛЯ iCustom() EA:                                          |
//|   0 = BullLine  (синяя часть Middle, EMPTY_VALUE если медведь)    |
//|   1 = BearLine  (красная часть Middle, EMPTY_VALUE если бык)      |
//|   2 = PurePPBuf (чистый классический PP3D — для сравнения)        |
//|   3 = R1Buf     (уровень сопротивления R1)                        |
//|   4 = S1Buf     (уровень поддержки S1)                            |
//|   5 = MiddleBuf (сырое значение Middle — всегда численное)        |
//|   6 = DirBuf    (+1 = бычий, -1 = медвежий, 0 = не определён)     |
//|                                                                   |
//| ПРИМЕР iCustom (с учётом всех input, включая разделители _sepN_): |
//|   double midNow = iCustom(NULL, 0, "PP_VWAP_Blend_v1_0",          |
//|                 "", 3, 0.3, true, true,                           |
//|                 "", clrDodgerBlue, clrOrangeRed, 2,               |
//|                 "", clrGray, 1, clrLimeGreen, clrOrange, 1,       |
//|                 "", false, false, false, false,                   |
//|                 5, 1);  // MiddleBuf, bar 1                        |
//|   double dir    = iCustom(NULL, 0, "PP_VWAP_Blend_v1_0",          |
//|                 "", 3, 0.3, true, true,                           |
//|                 "", clrDodgerBlue, clrOrangeRed, 2,               |
//|                 "", clrGray, 1, clrLimeGreen, clrOrange, 1,       |
//|                 "", false, false, false, false,                   |
//|                 6, 1);  // +1/-1 на bar 1                          |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| БЛОК 1: PROPERTY ДИРЕКТИВЫ                                       |
//+------------------------------------------------------------------+
#property copyright   "Ruslan Kuchma 2026"
#property link        "https://t.me/RuslanKuchma"
#property version     "1.00"
#property strict
#property description "PP_VWAP_Blend v1.0 — Pivot Point + VWAP смешанная средняя"
#property description "3-дневный пивот сглажен объёмно-взвешенным VWAP"
#property description "Middle = 0.3·PP3D + 0.7·VWAP3D, окраска по наклону"
#property description "Синий/красный цвет + R1/S1 уровни + чистый PP"

#property indicator_chart_window          // Индикатор на основном графике
#property indicator_buffers 5             // 5 видимых буферов (ещё 2 скрытых через IndicatorBuffers)

// --- Buffer 0: BullLine (Middle когда растёт) ---
#property indicator_label1  "Middle (Bull)"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// --- Buffer 1: BearLine (Middle когда падает) ---
#property indicator_label2  "Middle (Bear)"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrangeRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

// --- Buffer 2: PurePP (классический 3-дневный PP — пунктир) ---
#property indicator_label3  "Pure PP3D"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrGray
#property indicator_style3  STYLE_DOT
#property indicator_width3  1

// --- Buffer 3: R1 (сопротивление) ---
#property indicator_label4  "R1"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrLimeGreen
#property indicator_style4  STYLE_DOT
#property indicator_width4  1

// --- Buffer 4: S1 (поддержка) ---
#property indicator_label5  "S1"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrOrange
#property indicator_style5  STYLE_DOT
#property indicator_width5  1

// --- Buffer 5: MiddleRaw — скрытый служебный буфер для iCustom ---
// --- Buffer 6: Direction — скрытый служебный буфер +1/-1/0 для iCustom ---
// (настраиваются в OnInit через IndicatorBuffers(7))

//+------------------------------------------------------------------+
//| БЛОК 2: INPUT ПАРАМЕТРЫ                                          |
//+------------------------------------------------------------------+
input string _sep1_        = "=== Pivot + VWAP параметры ===";      // ─── Формула
input int    PivotDays     = 3;       // Окно в днях для H/L/C и VWAP (1..10)
input double Alpha         = 0.1;     // Вес PP (0=чистый VWAP, 1=чистый PP)
input bool   ShowPurePP    = true;    // Показывать чистый PP3D пунктиром
input bool   ShowLevels    = true;    // Показывать уровни R1/S1

input string _sep2_        = "=== Визуализация Middle ===";         // ─── Цвета Middle
input color  ColorBull     = clrDodgerBlue;   // Цвет бычьей части Middle
input color  ColorBear     = clrOrangeRed;    // Цвет медвежьей части Middle
input int    WidthMiddle   = 2;               // Толщина линии Middle (1..4)

input string _sep3_        = "=== Визуализация уровней ===";        // ─── Цвета уровней
input color  ColorPurePP   = clrGray;         // Цвет чистого PP3D
input int    WidthPurePP   = 1;               // Толщина чистого PP3D
input color  ColorR1       = clrBlue;    // Цвет R1
input color  ColorS1       = clrRed;       // Цвет S1
input int    WidthLevels   = 1;               // Толщина R1/S1

input string _sep4_        = "=== Алерты ===";                       // ─── Уведомления
input bool   AlertOnSignal = false;   // Включить алерт (Alert окно)
input bool   UseSoundAlert = false;   // Звуковой алерт
input bool   UseEmailAlert = false;   // Email-алерт
input bool   UsePushAlert  = false;   // Push-уведомление на телефон

//+------------------------------------------------------------------+
//| БЛОК 3: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И БУФЕРЫ                           |
//+------------------------------------------------------------------+
// Визуальные буферы
double BullLineBuf[];      // 0 — бычья часть Middle (синяя)
double BearLineBuf[];      // 1 — медвежья часть Middle (красная)
double PurePPBuf[];        // 2 — чистый PP3D
double R1Buf[];            // 3 — уровень R1
double S1Buf[];            // 4 — уровень S1

// Скрытые служебные буферы (для EA)
double MiddleBuf[];        // 5 — сырое значение Middle (всегда число)
double DirBuf[];           // 6 — направление (+1 / -1 / 0)

// Валидированные копии input-параметров
int    g_pivotDays   = 3;          // Проверенное число дней
double g_alpha       = 0.3;        // Проверенный вес PP
bool   g_showPurePP  = true;       // Показ чистого PP
bool   g_showLevels  = true;       // Показ уровней R1/S1

int    g_widthMiddle = 2;          // Толщина Middle
int    g_widthPurePP = 1;          // Толщина PurePP
int    g_widthLevels = 1;          // Толщина уровней

bool   g_alertOn     = false;      // Флаги алертов
bool   g_soundOn     = false;
bool   g_emailOn     = false;
bool   g_pushOn      = false;

// Защита алертов от повторов
datetime g_lastAlertTime = 0;

// Минимум баров на текущем TF для корректного расчёта
int    g_barsIn3Days = 72;         // Пересчитается в OnInit по Period()
int    g_minBarsNeed = 100;        // Минимум баров для работы

//+------------------------------------------------------------------+
//| БЛОК 4: OnInit() — ИНИЦИАЛИЗАЦИЯ                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 1. Валидация входных параметров
   g_pivotDays = (int)MathMax(1, MathMin(10, PivotDays));
   if(g_pivotDays != PivotDays)
      Print("⚠ PivotDays=", PivotDays, " вне [1..10], скорректировано до ", g_pivotDays);

   g_alpha = MathMax(0.0, MathMin(1.0, Alpha));
   if(g_alpha != Alpha)
      Print("⚠ Alpha=", Alpha, " вне [0.0..1.0], скорректировано до ", DoubleToString(g_alpha,2));

   g_widthMiddle = (int)MathMax(1, MathMin(5, WidthMiddle));
   g_widthPurePP = (int)MathMax(1, MathMin(3, WidthPurePP));
   g_widthLevels = (int)MathMax(1, MathMin(3, WidthLevels));

   g_showPurePP = ShowPurePP;
   g_showLevels = ShowLevels;
   g_alertOn    = AlertOnSignal;
   g_soundOn    = UseSoundAlert;
   g_emailOn    = UseEmailAlert;
   g_pushOn     = UsePushAlert;

   //--- 2. Расчёт количества баров в окне на текущем TF
   //    Period() возвращает минуты для внутридневных, 1440 для D1, 10080 для W1
   int minutesInWindow = g_pivotDays * 24 * 60;  // минут в окне
   int perMin = Period();                         // минут в одном баре
   if(perMin <= 0) perMin = 60;                   // защита (для H1 по умолчанию)
   g_barsIn3Days = (int)MathMax(3, minutesInWindow / perMin);

   // Минимум баров: окно VWAP + запас
   g_minBarsNeed = g_barsIn3Days + 10;

   //--- 3. Настройка буферов (всего 7, видимых 5)
   IndicatorBuffers(7);

   SetIndexBuffer(0, BullLineBuf);
   SetIndexBuffer(1, BearLineBuf);
   SetIndexBuffer(2, PurePPBuf);
   SetIndexBuffer(3, R1Buf);
   SetIndexBuffer(4, S1Buf);
   SetIndexBuffer(5, MiddleBuf);
   SetIndexBuffer(6, DirBuf);

   //--- 4. Стили линий (с учётом input-цветов и флагов показа)
   SetIndexStyle(0, DRAW_LINE, STYLE_SOLID, g_widthMiddle, ColorBull);
   SetIndexStyle(1, DRAW_LINE, STYLE_SOLID, g_widthMiddle, ColorBear);

   if(g_showPurePP)
      SetIndexStyle(2, DRAW_LINE, STYLE_DOT, g_widthPurePP, ColorPurePP);
   else
      SetIndexStyle(2, DRAW_NONE);

   if(g_showLevels)
   {
      SetIndexStyle(3, DRAW_LINE, STYLE_DOT, g_widthLevels, ColorR1);
      SetIndexStyle(4, DRAW_LINE, STYLE_DOT, g_widthLevels, ColorS1);
   }
   else
   {
      SetIndexStyle(3, DRAW_NONE);
      SetIndexStyle(4, DRAW_NONE);
   }

   // Скрытые служебные
   SetIndexStyle(5, DRAW_NONE);
   SetIndexStyle(6, DRAW_NONE);

   //--- 5. Подписи в Data Window
   SetIndexLabel(0, "Middle Bull");
   SetIndexLabel(1, "Middle Bear");
   SetIndexLabel(2, g_showPurePP ? "Pure PP3D" : NULL);
   SetIndexLabel(3, g_showLevels ? "R1" : NULL);
   SetIndexLabel(4, g_showLevels ? "S1" : NULL);
   SetIndexLabel(5, NULL);  // MiddleRaw — скрыт
   SetIndexLabel(6, NULL);  // Direction — скрыт

   //--- 6. Значения "пусто" для линий
   SetIndexEmptyValue(0, EMPTY_VALUE);
   SetIndexEmptyValue(1, EMPTY_VALUE);
   SetIndexEmptyValue(2, EMPTY_VALUE);
   SetIndexEmptyValue(3, EMPTY_VALUE);
   SetIndexEmptyValue(4, EMPTY_VALUE);
   SetIndexEmptyValue(5, EMPTY_VALUE);
   SetIndexEmptyValue(6, 0.0);

   //--- 7. Инициализация буферов
   ArrayInitialize(BullLineBuf, EMPTY_VALUE);
   ArrayInitialize(BearLineBuf, EMPTY_VALUE);
   ArrayInitialize(PurePPBuf,   EMPTY_VALUE);
   ArrayInitialize(R1Buf,       EMPTY_VALUE);
   ArrayInitialize(S1Buf,       EMPTY_VALUE);
   ArrayInitialize(MiddleBuf,   EMPTY_VALUE);
   ArrayInitialize(DirBuf,      0.0);

   //--- 8. Имя в окне котировки
   string sname = StringFormat("PP_VWAP_Blend(%d,%.2f)", g_pivotDays, g_alpha);
   IndicatorShortName(sname);
   IndicatorDigits(_Digits);

   //--- 9. Сброс состояния алертов
   g_lastAlertTime = 0;

   //--- 10. Лог запуска
   Print("═══════════════════════════════════════════════════");
   Print("PP_VWAP_Blend v1.0 запущен | Symbol: ", Symbol(), " | TF: ", GetTFName(_Period));
   Print("PivotDays = ", g_pivotDays, " дн. | Alpha = ", DoubleToString(g_alpha,2),
         " (PP=", DoubleToString(g_alpha*100,0), "%, VWAP=",
         DoubleToString((1-g_alpha)*100,0), "%)");
   Print("VWAP окно на текущем TF: ", g_barsIn3Days, " баров");
   Print("ShowPurePP=", g_showPurePP, " | ShowLevels=", g_showLevels);
   Print("Алерты: Alert=", g_alertOn, " Sound=", g_soundOn,
         " Email=", g_emailOn, " Push=", g_pushOn);
   Print("═══════════════════════════════════════════════════");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 5: OnDeinit() — ДЕИНИЦИАЛИЗАЦИЯ                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("PP_VWAP_Blend деинициализирован. Код причины: ", reason);
}

//+------------------------------------------------------------------+
//| БЛОК 6: OnCalculate() — ОСНОВНОЙ РАСЧЁТ                          |
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
   //--- 1. Проверка минимума баров
   if(rates_total < g_minBarsNeed)
      return(0);

   //--- 2. Определение диапазона пересчёта
   int limit;
   if(prev_calculated == 0)
   {
      // Первый запуск — считаем всю доступную историю
      limit = rates_total - g_barsIn3Days - 2;
      // Инициализация скрытых буферов на "старом хвосте"
      for(int j = rates_total - 1; j > limit; j--)
      {
         SetEmptyValues(j);
      }
   }
   else
   {
      // Инкрементально: только новые бары + 1 для коррекции
      limit = rates_total - prev_calculated + 1;
   }

   // Защита границ
   if(limit >= rates_total - 1) limit = rates_total - 2;
   if(limit < 1) limit = 1;

   //--- 3. Основной цикл (антирепейнт: i >= 1, бар 0 НЕ считается)
   for(int i = limit; i >= 1; i--)
   {
      // Границы окна VWAP
      if(i + g_barsIn3Days >= rates_total)
      {
         SetEmptyValues(i);
         continue;
      }

      //--- 3.1 Поиск D1-баров для PP3D
      // Номер D1-бара, которому принадлежит бар i
      int d_shift = iBarShift(NULL, PERIOD_D1, time[i], false);
      if(d_shift < 0)
      {
         SetEmptyValues(i);
         continue;
      }

      // Для антирепейнта: всегда 3 ЗАВЕРШЁННЫХ дня ДО текущего дня бара i
      int dayFrom = d_shift + 1;
      int dayTo   = d_shift + g_pivotDays;

      int totalD1 = iBars(NULL, PERIOD_D1);
      if(dayTo >= totalD1)
      {
         SetEmptyValues(i);
         continue;
      }

      //--- 3.2 Расчёт H3, L3 (экстремумы за g_pivotDays завершённых D1)
      double H3 = iHigh(NULL, PERIOD_D1, dayFrom);
      double L3 = iLow(NULL,  PERIOD_D1, dayFrom);
      if(H3 <= 0.0 || L3 <= 0.0)
      {
         SetEmptyValues(i);
         continue;
      }

      for(int d = dayFrom + 1; d <= dayTo; d++)
      {
         double h = iHigh(NULL, PERIOD_D1, d);
         double l = iLow(NULL,  PERIOD_D1, d);
         if(h <= 0.0 || l <= 0.0) continue;   // пропуск плохих данных
         if(h > H3) H3 = h;
         if(l < L3) L3 = l;
      }

      // C3 = Close последнего завершённого D1 (первый день окна = самый свежий)
      double C3 = iClose(NULL, PERIOD_D1, dayFrom);
      if(C3 <= 0.0)
      {
         SetEmptyValues(i);
         continue;
      }

      //--- 3.3 Классический 3-дневный Pivot и уровни R1/S1
      double PP3D = (H3 + L3 + C3) / 3.0;
      double R1   = 2.0 * PP3D - L3;
      double S1   = 2.0 * PP3D - H3;

      //--- 3.4 VWAP3D: объёмно-взвешенная цена за окно на текущем TF
      double sumPV = 0.0;
      double sumV  = 0.0;
      double sumTP = 0.0;  // для fallback если объёмы все нулевые

      for(int k = i; k < i + g_barsIn3Days; k++)
      {
         double tp = (high[k] + low[k] + close[k]) / 3.0;
         double v  = (double)tick_volume[k];
         if(v < 1.0) v = 1.0;   // защита от нулевого объёма
         sumPV += tp * v;
         sumV  += v;
         sumTP += tp;
      }

      double VWAP3D;
      if(sumV < 1.0)
      {
         // Fallback: простое среднее TP если все объёмы = 0 (редко, но возможно)
         VWAP3D = sumTP / (double)g_barsIn3Days;
      }
      else
      {
         VWAP3D = sumPV / sumV;
      }

      //--- 3.5 Средняя линия (Middle) — главный результат индикатора
      double Middle = g_alpha * PP3D + (1.0 - g_alpha) * VWAP3D;
      Middle = NormalizeDouble(Middle, _Digits);

      // Сохраняем в "сырой" буфер — всегда численное значение (для EA)
      MiddleBuf[i] = Middle;
      PurePPBuf[i] = g_showPurePP ? NormalizeDouble(PP3D, _Digits) : EMPTY_VALUE;
      R1Buf[i]     = g_showLevels ? NormalizeDouble(R1,   _Digits) : EMPTY_VALUE;
      S1Buf[i]     = g_showLevels ? NormalizeDouble(S1,   _Digits) : EMPTY_VALUE;

      //--- 3.6 Определение направления (цвета) по наклону
      int dir = 0;
      double prevMiddle = MiddleBuf[i + 1];

      if(prevMiddle != EMPTY_VALUE)
      {
         if(Middle > prevMiddle + _Point * 0.5)
            dir = 1;                         // растёт → бык
         else if(Middle < prevMiddle - _Point * 0.5)
            dir = -1;                        // падает → медведь
         else
         {
            // Равенство — сохраняем прошлое направление
            int prevDir = (int)DirBuf[i + 1];
            dir = (prevDir != 0) ? prevDir : 1;
         }
      }
      else
      {
         // Самый первый расчёт — по умолчанию бык
         dir = 1;
      }

      DirBuf[i] = (double)dir;

      //--- 3.7 Окраска: распределение Middle по Bull/Bear буферам
      if(dir == 1)
      {
         BullLineBuf[i] = Middle;
         BearLineBuf[i] = EMPTY_VALUE;

         // Связка при смене цвета: если прошлый был медведь, добавляем
         // значение в BullBuf на прошлом баре, чтобы линия не разорвалась
         if(i + 1 < rates_total && (int)DirBuf[i + 1] == -1 &&
            MiddleBuf[i + 1] != EMPTY_VALUE)
         {
            BullLineBuf[i + 1] = MiddleBuf[i + 1];
         }
      }
      else // dir == -1
      {
         BearLineBuf[i] = Middle;
         BullLineBuf[i] = EMPTY_VALUE;

         // Связка при смене цвета
         if(i + 1 < rates_total && (int)DirBuf[i + 1] == 1 &&
            MiddleBuf[i + 1] != EMPTY_VALUE)
         {
            BearLineBuf[i + 1] = MiddleBuf[i + 1];
         }
      }
   }

   //--- 4. Антирепейнт: бар 0 явно пустой
   SetEmptyValues(0);

   //--- 5. Алерты (только на закрытом баре 1, один раз)
   if(rates_total > 3 && prev_calculated > 0)
      CheckAlerts(time);

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                  |
//+------------------------------------------------------------------+

//--- Обнуление всех буферов на баре bar (для пропуска / антирепейнта)
void SetEmptyValues(int bar)
{
   if(bar < 0) return;
   BullLineBuf[bar] = EMPTY_VALUE;
   BearLineBuf[bar] = EMPTY_VALUE;
   PurePPBuf[bar]   = EMPTY_VALUE;
   R1Buf[bar]       = EMPTY_VALUE;
   S1Buf[bar]       = EMPTY_VALUE;
   MiddleBuf[bar]   = EMPTY_VALUE;
   DirBuf[bar]      = 0.0;
}

//--- Проверка алертов: смена цвета на закрытом баре 1
void CheckAlerts(const datetime &time[])
{
   if(!g_alertOn && !g_soundOn && !g_emailOn && !g_pushOn) return;

   // Направление на барах 1 и 2
   double d1 = DirBuf[1];
   double d2 = DirBuf[2];

   if(d1 == 0.0 || d2 == 0.0) return;         // нет данных
   if(d1 == d2) return;                       // цвет не сменился

   // Один алерт на бар
   if(time[1] <= g_lastAlertTime) return;
   g_lastAlertTime = time[1];

   string directionStr = (d1 > 0.0) ? "СИНИЙ ▲ бычий" : "КРАСНЫЙ ▼ медвежий";
   double midVal = MiddleBuf[1];
   string midStr = (midVal != EMPTY_VALUE) ? DoubleToString(midVal, _Digits) : "n/a";

   string msg = StringFormat("PP_VWAP_Blend [%s %s]: смена цвета → %s @ Middle=%s",
                             Symbol(), GetTFName(_Period), directionStr, midStr);

   if(g_alertOn) Alert(msg);
   if(g_soundOn) PlaySound("alert.wav");
   if(g_emailOn) SendMail("PP_VWAP_Blend сигнал", msg);
   if(g_pushOn)  SendNotification(msg);
}

//--- Строковое имя таймфрейма
string GetTFName(int period)
{
   switch(period)
   {
      case PERIOD_M1:  return("M1");
      case PERIOD_M5:  return("M5");
      case PERIOD_M15: return("M15");
      case PERIOD_M30: return("M30");
      case PERIOD_H1:  return("H1");
      case PERIOD_H4:  return("H4");
      case PERIOD_D1:  return("D1");
      case PERIOD_W1:  return("W1");
      case PERIOD_MN1: return("MN1");
   }
   return("TF" + IntegerToString(period));
}

//+------------------------------------------------------------------+
//|                           КОНЕЦ ФАЙЛА                             |
//+------------------------------------------------------------------+
