//+------------------------------------------------------------------+
//|                                     AutomatedTrendLines_v2_0.mq4 |
//|        Автоматические трендовые линии по swing-точкам (РЕФАКТОР) |
//|                                  Copyright © 2026, Ruslan Kuchma |
//+------------------------------------------------------------------+
//| КОНЦЕПЦИЯ:                                                       |
//|   Индикатор автоматически находит swing-точки (peaks/troughs) и  |
//|   строит по ним горизонтальные и наклонные трендовые линии.      |
//|   Формула расчёта идентична оригиналу Ryan Sheehy v2.0           |
//|   (CurrencySecrets.com) — изменена ТОЛЬКО логика отрисовки для   |
//|   устранения загромождения графика старыми неактуальными линиями.|
//|                                                                  |
//| ФОРМУЛА (100% сохранена):                                        |
//|   1. Swing Peak:   High[i+1] > High[i] && High[i+1] >= High[i+2] |
//|      Swing Trough: Low[i+1]  < Low[i]  && Low[i+1]  <= Low[i+2]  |
//|   2. Параметр level (0..2) — глубина группировки swing-точек.    |
//|   3. countHCrosses:  считает касания/пробои горизонт. уровня.    |
//|   4. countSlopingCrosses: касания/пробои наклонной линии.        |
//|   5. Условие валидности:  touches > tch && brokenBar <= lineLife |
//|                                                                  |
//| РЕШЕНИЕ ПРОБЛЕМЫ ЗАГРОМОЖДЕНИЯ:                                  |
//|   • ShowBrokenLines=false  → убирает пунктирные "broken" линии,  |
//|     которые с OBJPROP_RAY=true тянутся вправо до бесконечности.  |
//|   • MaxSlopingLines        → ограничение top-N наклонных по      |
//|     свежести (ближе к текущему бару — релевантнее).              |
//|   • MaxHorizontalLines     → ограничение top-N горизонтальных по |
//|     близости уровня к текущей цене.                              |
//|   • MaxDistancePips        → отсечение линий дальше N пунктов    |
//|     от текущей цены (пустая зона графика).                       |
//|   • MaxScanBars            → ограничение глубины сканирования    |
//|     swing-точек (вместо всей истории).                           |
//|   • ShowSwingLabels        → опциональное скрытие меток ^ swing. |
//|                                                                  |
//| БЕЗОПАСНОСТЬ:                                                    |
//|   Все объекты индикатора имеют префикс "ATL_v20_" — пользова-    |
//|   тельские объекты на графике НЕ удаляются (в отличие от ориги-  |
//|   нала, где ObjectsDeleteAll(0) сносил ВСЁ подряд).              |
//+------------------------------------------------------------------+

#property copyright "Copyright © 2026, Ruslan Kuchma"
#property link      "https://t.me/RuslanKuchma"
#property version   "2.00"
#property strict
#property description "Automated Trend Lines v2.0 — рефакторинг с фильтрацией неактуальных линий."
#property description "Формула Ryan Sheehy (v2.0) сохранена 100%, изменена только отрисовка."
#property description "Параметры: ShowBrokenLines, MaxSlopingLines, MaxHorizontalLines, MaxDistancePips."

#property indicator_chart_window      // Индикатор рисует на основном графике
#property indicator_buffers 0         // Буферы не используются — только графические объекты

//+------------------------------------------------------------------+
//| БЛОК 1: ВХОДНЫЕ ПАРАМЕТРЫ                                        |
//+------------------------------------------------------------------+

//--- Параметры формулы (идентичны оригиналу) ---
input string  _s1_            = "=== Формула (оригинал) ===";     // ───
input int     Level           = 0;            // Уровень swing (0..2): глубина группировки
input int     Breaks          = 2;            // Макс. пробоев для "живой" линии
input int     Touches         = 2;            // Мин. касаний для отрисовки линии
input int     LineLife        = 30;           // Сколько баров показывать пробитую линию
input bool    BodyIsBreak     = false;        // Тело свечи за линией = пробой? (false=только Close)

//--- ФИЛЬТРЫ ОТРИСОВКИ (решение проблемы загромождения) ---
input string  _s2_            = "=== Фильтры отрисовки ===";      // ───
input bool    ShowBrokenLines = false;        // Показывать пунктирные пробитые линии
input int     MaxSlopingLines = 4;            // Макс. наклонных линий (0=без лимита)
input int     MaxHorizontalLines = 6;         // Макс. горизонтальных линий (0=без лимита)
input int     MaxDistancePips = 300;          // Макс. дистанция от цены до уровня, пунктов (0=без лимита)
input int     MaxScanBars     = 1500;         // Макс. баров для поиска swing (0=вся история)
input bool    ShowSwingLabels = false;        // Показывать символы ^ на swing-точках
input bool    ShowPriceLabels = false;         // Показывать ценовые подписи рядом с гориз. линиями

//--- Визуализация ---
input string  _s3_            = "=== Визуализация ===";           // ───
input color   ResColor        = clrRed;       // Цвет сопротивления (горизонтальное)
input color   SupColor        = clrBlue;      // Цвет поддержки (горизонтальное)
input color   SlopeResColor   = clrLightPink; // Цвет наклонного сопротивления
input color   SlopeSupColor   = clrLightBlue; // Цвет наклонной поддержки
input int     LineWidth       = 1;            // Толщина активных линий
input int     LabelFontSize   = 10;           // Размер шрифта меток
input string  LabelFontFace   = "Times New Roman"; // Шрифт меток

//+------------------------------------------------------------------+
//| БЛОК 2: КОНСТАНТЫ И ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                        |
//+------------------------------------------------------------------+

#define OBJ_PREFIX "ATL_v20_"      // Префикс всех объектов индикатора (безопасное удаление)

//--- Валидированные копии input-параметров ---
int      g_level;                   // Копия Level (0..2)
int      g_breaks;                  // Копия Breaks
int      g_touches;                 // Копия Touches
int      g_lineLife;                // Копия LineLife
bool     g_bodyIsBreak;             // Копия BodyIsBreak
bool     g_showBroken;              // Копия ShowBrokenLines
int      g_maxSloping;              // Копия MaxSlopingLines
int      g_maxHorizontal;           // Копия MaxHorizontalLines
int      g_maxDistPips;             // Копия MaxDistancePips
int      g_maxScanBars;             // Копия MaxScanBars
bool     g_showSwingLabels;         // Копия ShowSwingLabels
bool     g_showPriceLabels;         // Копия ShowPriceLabels

//--- Рабочие переменные ---
datetime g_lastBarTime = 0;         // Время последнего обработанного бара (для пересчёта при смене TF-бара)
double   g_textPad     = 0.0;       // Отступ для текстовых меток (в ценовых единицах)
double   g_maxDist     = 0.0;       // Макс. дистанция в ценовых единицах (из MaxDistancePips)

//--- Структура кандидата для наклонной линии ---
struct SlopingLineCandidate
{
   int    fromBar;       // Первый анкер (более старый swing)
   int    toBar;         // Второй анкер (более новый swing)
   double priceFrom;     // Цена первой точки (High или Low)
   double priceTo;       // Цена второй точки
   double endLine;       // Экстраполяция на bar[0]
   double xLine;         // Значение линии на баре пробоя
   int    brokenBar;     // Бар пробоя (0 если не пробита)
   int    touches;       // Количество касаний
   bool   isResistance;  // true=Res (пики), false=Sup (впадины)
   int    freshness;     // Для ранжирования: min(fromBar,toBar) — чем меньше, тем свежее
};

//--- Структура кандидата для горизонтальной линии ---
struct HorizontalLineCandidate
{
   int    fromBar;       // Анкер-бар swing
   double price;         // Цена уровня (High или Low)
   int    brokenBar;     // Бар пробоя (0 если не пробита)
   int    touches;       // Количество касаний
   bool   isResistance;  // true=Res, false=Sup
   double distToPrice;   // Абсолютная дистанция до текущей цены (для ранжирования)
};

//+------------------------------------------------------------------+
//| БЛОК 3: OnInit — ИНИЦИАЛИЗАЦИЯ                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Валидация входных параметров ---
   g_level = Level;
   if(g_level < 0) { g_level = 0; Print("ВНИМАНИЕ: Level < 0, установлено 0"); }
   if(g_level > 2) { g_level = 2; Print("ВНИМАНИЕ: Level > 2, установлено 2"); }
   
   g_breaks = Breaks;
   if(g_breaks < 1) { g_breaks = 1; Print("ВНИМАНИЕ: Breaks < 1, установлено 1"); }
   
   g_touches = Touches;
   if(g_touches < 1) { g_touches = 1; Print("ВНИМАНИЕ: Touches < 1, установлено 1"); }
   
   g_lineLife = LineLife;
   if(g_lineLife < 0) { g_lineLife = 0; Print("ВНИМАНИЕ: LineLife < 0, установлено 0"); }
   
   g_bodyIsBreak      = BodyIsBreak;
   g_showBroken       = ShowBrokenLines;
   g_showSwingLabels  = ShowSwingLabels;
   g_showPriceLabels  = ShowPriceLabels;
   
   g_maxSloping = MaxSlopingLines;
   if(g_maxSloping < 0) g_maxSloping = 0;
   
   g_maxHorizontal = MaxHorizontalLines;
   if(g_maxHorizontal < 0) g_maxHorizontal = 0;
   
   g_maxDistPips = MaxDistancePips;
   if(g_maxDistPips < 0) g_maxDistPips = 0;
   
   g_maxScanBars = MaxScanBars;
   if(g_maxScanBars < 0) g_maxScanBars = 0;
   
   //--- Пересчёт пунктов в ценовые единицы ---
   // На 5-значных котировках 1 "пункт" трейдера = 10 × _Point
   double pipValue = _Point * ((_Digits == 3 || _Digits == 5) ? 10.0 : 1.0);
   g_maxDist = (g_maxDistPips > 0) ? g_maxDistPips * pipValue : 0.0;
   
   //--- Удаление своих объектов при старте (чистое поле) ---
   DeleteOwnObjects();
   
   //--- Краткое имя индикатора ---
   IndicatorShortName(StringFormat("AutoTrendLines v2.0 (L=%d, Br=%d, Tch=%d)",
                                    g_level, g_breaks, g_touches));
   
   g_lastBarTime = 0;  // Принудительный пересчёт на первом тике
   
   Print("AutoTrendLines v2.0 инициализирован: Level=", g_level,
         " Breaks=", g_breaks, " Touches=", g_touches, " LineLife=", g_lineLife,
         " ShowBroken=", g_showBroken, " MaxSlope=", g_maxSloping,
         " MaxHoriz=", g_maxHorizontal, " MaxDistPips=", g_maxDistPips,
         " ScanBars=", g_maxScanBars);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 4: OnDeinit — ДЕИНИЦИАЛИЗАЦИЯ                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteOwnObjects();    // Удаляем ТОЛЬКО свои объекты (не пользовательские!)
   Comment("");
   Print("AutoTrendLines v2.0 деинициализирован. Код: ", reason);
}

//+------------------------------------------------------------------+
//| БЛОК 5: OnCalculate — ОСНОВНОЙ РАСЧЁТ                            |
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
   //--- Минимум баров для работы ---
   if(rates_total < 10) return(0);
   
   //--- Пересчитываем только при появлении нового бара (как в оригинале) ---
   if(Time[0] == g_lastBarTime) return(rates_total);
   g_lastBarTime = Time[0];
   
   //--- Отступ для текстовых меток (зависит от TF и цены инструмента) ---
   g_textPad = _Point * Period();
   
   //--- Удаляем свои прежние объекты и перерисовываем ---
   DeleteOwnObjects();
   PlotAllLines();
   
   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 6: ОСНОВНАЯ ЛОГИКА — PlotAllLines                          |
//|    Сканирует swing-точки (1:1 формула оригинала), собирает       |
//|    кандидатов, ранжирует и рисует только top-N актуальных.       |
//+------------------------------------------------------------------+
void PlotAllLines()
{
   //=== ШАГ 1: Сканирование swing-точек (формула оригинала 1:1) ===
   
   int pkArr[]; ArrayResize(pkArr, 1); pkArr[0] = 0;    // Массив индексов пиков
   int trArr[]; ArrayResize(trArr, 1); trArr[0] = 0;    // Массив индексов впадин
   int p = 0;                                            // Счётчик пиков
   int t = 0;                                            // Счётчик впадин
   
   // Аккумуляторы для level>0 (как в оригинале)
   // ВАЖНО: в оригинале были не инициализированы — возможный UB. Здесь = 0.
   int pk0A = 0, pk0B = 0, pk0C = 0;
   int pk1A = 0, pk1B = 0, pk1C = 0;
   int tr0A = 0, tr0B = 0, tr0C = 0;
   int tr1A = 0, tr1B = 0, tr1C = 0;
   
   // Предел сканирования: MaxScanBars или весь график
   int scanLimit = (g_maxScanBars > 0 && g_maxScanBars < Bars - 2) ? g_maxScanBars : (Bars - 2);
   
   // Цикл поиска swing (формула 1:1 с оригиналом)
   for(int i = 1; i < scanLimit; i++)
   {
      //--- Обнаружение свечи-пика: High[i+1] > High[i] && High[i+1] >= High[i+2] ---
      if(High[i+1] > High[i] && High[i+1] >= High[i+2])
      {
         pk0C = pk0B;          // Сдвигаем "окно" level-1
         pk0B = pk0A;
         pk0A = i + 1;
         
         if(g_level < 1)
         {
            // Level=0: все swing-пики записываются сразу
            if(p > 0) ArrayResize(pkArr, p + 1);
            pkArr[p] = i + 1;
            if(g_showSwingLabels) DrawSwingLabel(pk0A, true);   // Символ ^ сверху
            p++;
         }
         else if(pk0C > 0 && High[pk0B] > High[pk0A] && High[pk0B] >= High[pk0C])
         {
            // Level=1: пик внутри группы из трёх pk0A/pk0B/pk0C
            pk1C = pk1B; pk1B = pk1A; pk1A = pk0B;
            
            if(g_level < 2)
            {
               if(p > 0) ArrayResize(pkArr, p + 1);
               pkArr[p] = pk0B;
               if(g_showSwingLabels) DrawSwingLabel(pk0B, true);
               p++;
            }
            else if(pk1C > 0 && High[pk1B] > High[pk1A] && High[pk1B] >= High[pk1C])
            {
               // Level=2: пик второго порядка
               if(p > 0) ArrayResize(pkArr, p + 1);
               pkArr[p] = pk1B;
               if(g_showSwingLabels) DrawSwingLabel(pk1B, true);
               p++;
            }
         }
      }
      
      //--- Обнаружение свечи-впадины: Low[i+1] < Low[i] && Low[i+1] <= Low[i+2] ---
      if(Low[i+1] < Low[i] && Low[i+1] <= Low[i+2])
      {
         tr0C = tr0B;
         tr0B = tr0A;
         tr0A = i + 1;
         
         if(g_level < 1)
         {
            if(t > 0) ArrayResize(trArr, t + 1);
            trArr[t] = i + 1;
            if(g_showSwingLabels) DrawSwingLabel(tr0A, false);
            t++;
         }
         else if(tr0C > 1 && Low[tr0B] < Low[tr0A] && Low[tr0B] <= Low[tr0C])
         {
            tr1C = tr1B; tr1B = tr1A; tr1A = tr0B;
            
            if(g_level < 2)
            {
               if(t > 0) ArrayResize(trArr, t + 1);
               trArr[t] = tr0B;
               if(g_showSwingLabels) DrawSwingLabel(tr0B, false);
               t++;
            }
            else if(tr1C > 0 && Low[tr1B] < Low[tr1A] && Low[tr1B] <= Low[tr1C])
            {
               if(t > 0) ArrayResize(trArr, t + 1);
               trArr[t] = tr1B;
               if(g_showSwingLabels) DrawSwingLabel(tr1B, false);
               t++;
            }
         }
      }
   }
   
   //=== ШАГ 2: Сбор кандидатов-линий (формула countHCrosses/countSlopingCrosses 1:1) ===
   
   HorizontalLineCandidate hCandidates[];    // Горизонтальные кандидаты
   SlopingLineCandidate    sCandidates[];    // Наклонные кандидаты
   ArrayResize(hCandidates, 0);
   ArrayResize(sCandidates, 0);
   
   double currentPrice = (Bid + Ask) / 2.0;  // Текущая цена для ранжирования
   
   //--- PEAKS: горизонтальные сопротивления + наклонные сопротивления ---
   if(ArraySize(pkArr) > 1)
   {
      ArraySort(pkArr, WHOLE_ARRAY, 0, MODE_DESCEND);   // Свежие — в конец
      int a = ArraySize(pkArr);
      for(int i = 0; i < a; i++)
      {
         // Горизонтальная линия (формула countHCrosses)
         int touches, brokenBar;
         CountHCrosses(pkArr[i], g_breaks, 0.0, true, g_bodyIsBreak, touches, brokenBar);
         if(touches > g_touches && brokenBar <= g_lineLife)
         {
            // Применяем фильтр дистанции
            double distToPrice = MathAbs(High[pkArr[i]] - currentPrice);
            if(g_maxDist == 0.0 || distToPrice <= g_maxDist)
            {
               int idx = ArraySize(hCandidates);
               ArrayResize(hCandidates, idx + 1);
               hCandidates[idx].fromBar      = pkArr[i];
               hCandidates[idx].price        = High[pkArr[i]];
               hCandidates[idx].brokenBar    = brokenBar;
               hCandidates[idx].touches      = touches;
               hCandidates[idx].isResistance = true;
               hCandidates[idx].distToPrice  = distToPrice;
            }
         }
         
         // Наклонные линии (формула countSlopingCrosses)
         for(int j = i + 1; j < a; j++)
         {
            int tS, xS;
            CountSlopingCrosses(pkArr[i], pkArr[j], g_breaks, 0.0, true, g_bodyIsBreak, tS, xS);
            if(tS > g_touches && xS <= g_lineLife)
            {
               double slope   = (High[pkArr[i]] - High[pkArr[j]]) / (double)(pkArr[i] - pkArr[j]);
               double endLine = (slope * (0 - pkArr[i])) + High[pkArr[i]];
               double xLine   = (slope * (xS - pkArr[i])) + High[pkArr[i]];
               
               // Фильтр: наклонная линия где-то рядом с ценой (на баре 0)
               double distSlopeToPrice = MathAbs(endLine - currentPrice);
               if(g_maxDist == 0.0 || distSlopeToPrice <= g_maxDist)
               {
                  int idx = ArraySize(sCandidates);
                  ArrayResize(sCandidates, idx + 1);
                  sCandidates[idx].fromBar      = pkArr[i];
                  sCandidates[idx].toBar        = pkArr[j];
                  sCandidates[idx].priceFrom    = High[pkArr[i]];
                  sCandidates[idx].priceTo      = High[pkArr[j]];
                  sCandidates[idx].endLine      = endLine;
                  sCandidates[idx].xLine        = xLine;
                  sCandidates[idx].brokenBar    = xS;
                  sCandidates[idx].touches      = tS;
                  sCandidates[idx].isResistance = true;
                  sCandidates[idx].freshness    = MathMin(pkArr[i], pkArr[j]);
               }
            }
         }
      }
   }
   
   //--- TROUGHS: горизонтальные поддержки + наклонные поддержки ---
   if(ArraySize(trArr) > 1)
   {
      ArraySort(trArr, WHOLE_ARRAY, 0, MODE_DESCEND);
      int a = ArraySize(trArr);
      for(int i = 0; i < a; i++)
      {
         int touches, brokenBar;
         CountHCrosses(trArr[i], g_breaks, 0.0, false, g_bodyIsBreak, touches, brokenBar);
         if(touches > g_touches && brokenBar <= g_lineLife)
         {
            double distToPrice = MathAbs(Low[trArr[i]] - currentPrice);
            if(g_maxDist == 0.0 || distToPrice <= g_maxDist)
            {
               int idx = ArraySize(hCandidates);
               ArrayResize(hCandidates, idx + 1);
               hCandidates[idx].fromBar      = trArr[i];
               hCandidates[idx].price        = Low[trArr[i]];
               hCandidates[idx].brokenBar    = brokenBar;
               hCandidates[idx].touches      = touches;
               hCandidates[idx].isResistance = false;
               hCandidates[idx].distToPrice  = distToPrice;
            }
         }
         
         for(int j = i + 1; j < a; j++)
         {
            int tS, xS;
            CountSlopingCrosses(trArr[i], trArr[j], g_breaks, 0.0, false, g_bodyIsBreak, tS, xS);
            if(tS > g_touches && xS <= g_lineLife)
            {
               double slope   = (Low[trArr[i]] - Low[trArr[j]]) / (double)(trArr[i] - trArr[j]);
               double endLine = (slope * (0 - trArr[i])) + Low[trArr[i]];
               double xLine   = (slope * (xS - trArr[i])) + Low[trArr[i]];
               
               double distSlopeToPrice = MathAbs(endLine - currentPrice);
               if(g_maxDist == 0.0 || distSlopeToPrice <= g_maxDist)
               {
                  int idx = ArraySize(sCandidates);
                  ArrayResize(sCandidates, idx + 1);
                  sCandidates[idx].fromBar      = trArr[i];
                  sCandidates[idx].toBar        = trArr[j];
                  sCandidates[idx].priceFrom    = Low[trArr[i]];
                  sCandidates[idx].priceTo      = Low[trArr[j]];
                  sCandidates[idx].endLine      = endLine;
                  sCandidates[idx].xLine        = xLine;
                  sCandidates[idx].brokenBar    = xS;
                  sCandidates[idx].touches      = tS;
                  sCandidates[idx].isResistance = false;
                  sCandidates[idx].freshness    = MathMin(trArr[i], trArr[j]);
               }
            }
         }
      }
   }
   
   //=== ШАГ 3: Ранжирование и отрисовка top-N ===
   
   //--- Сортировка горизонтальных: непробитые первыми, затем по близости к цене ---
   SortHorizontals(hCandidates);
   int hTotal = ArraySize(hCandidates);
   int hLimit = (g_maxHorizontal > 0) ? g_maxHorizontal : INT_MAX;
   int hDrawn = 0;
   for(int i = 0; i < hTotal && hDrawn < hLimit; i++)
   {
      // Пропускаем пробитые если отображение пунктирных линий отключено
      if(!g_showBroken && hCandidates[i].brokenBar > 0) continue;
      DrawHorizontalLine(hCandidates[i]);
      hDrawn++;
   }
   
   //--- Сортировка наклонных: непробитые первыми, затем по свежести ---
   SortSlopings(sCandidates);
   int sTotal = ArraySize(sCandidates);
   int sLimit = (g_maxSloping > 0) ? g_maxSloping : INT_MAX;
   int sDrawn = 0;
   for(int i = 0; i < sTotal && sDrawn < sLimit; i++)
   {
      if(!g_showBroken && sCandidates[i].brokenBar > 0) continue;
      DrawSlopingLine(sCandidates[i]);
      sDrawn++;
   }
}

//+------------------------------------------------------------------+
//| БЛОК 7: ФОРМУЛА countHCrosses (1:1 из оригинала)                 |
//|    Считает касания и пробои горизонтальной линии.                |
//|    Возвращает через out-параметры: touches, lastCross.           |
//+------------------------------------------------------------------+
void CountHCrosses(int fromBar, int brkLimit, double rng, bool isPeak, bool body,
                   int &touchesOut, int &lastCrossOut)
{
   int t = 0, x = 0, lastCross = 0;
   bool flag;
   double refPrice = isPeak ? High[fromBar] : Low[fromBar];
   
   // Цикл от fromBar в сторону настоящего (i > 0, чтобы не трогать bar[0])
   for(int i = fromBar; i > 0; i--)
   {
      flag = true;
      if(isPeak)
      {
         // Горизонтальное сопротивление — смотрим Highs
         if(High[i] + rng >= refPrice) t++;             // Касание
         if(body && Open[i] > refPrice)                  // Тело как пробой
         {
            flag = false;   // Чтобы не посчитать Close дважды
            x++;
         }
         if(flag && Close[i] > refPrice) x++;           // Close как пробой
      }
      else
      {
         // Горизонтальная поддержка — смотрим Lows
         if(Low[i] - rng <= refPrice) t++;
         if(body && Open[i] < refPrice)
         {
            flag = false;
            x++;
         }
         if(flag && Close[i] < refPrice) x++;
      }
      
      // Если пробоев больше лимита — фиксируем бар первого финального пробоя
      if(x > brkLimit && brkLimit > 0)
      {
         lastCross = i;
         break;
      }
   }
   
   touchesOut   = t;
   lastCrossOut = lastCross;
}

//+------------------------------------------------------------------+
//| БЛОК 8: ФОРМУЛА countSlopingCrosses (1:1 из оригинала)           |
//|    Считает касания и пробои НАКЛОННОЙ линии, определённой        |
//|    двумя точками (fromBar, toBar).                               |
//+------------------------------------------------------------------+
void CountSlopingCrosses(int fromBar, int toBar, int brkLimit, double rng,
                         bool isPeak, bool body,
                         int &touchesOut, int &lastCrossOut)
{
   int t = 0, x = 0, lastCross = 0;
   bool flag;
   double slope, val;
   
   // Защита от деления на ноль
   if(fromBar == toBar)
   {
      touchesOut   = 0;
      lastCrossOut = 0;
      return;
   }
   
   // Наклон линии (формула оригинала 1:1)
   if(isPeak)
      slope = (High[fromBar] - High[toBar]) / (double)(fromBar - toBar);
   else
      slope = (Low[fromBar]  - Low[toBar])  / (double)(fromBar - toBar);
   
   // Сканирование от fromBar в сторону настоящего
   for(int i = fromBar; i > 0; i--)
   {
      flag = true;
      if(isPeak)
      {
         val = (slope * (i - fromBar)) + High[fromBar]; // Значение наклонной на баре i
         if(High[i] + rng >= val) t++;
         if(body && Open[i] > val)
         {
            flag = false;
            x++;
         }
         if(flag && Close[i] > val) x++;
      }
      else
      {
         val = (slope * (i - fromBar)) + Low[fromBar];
         if(Low[i] - rng <= val) t++;
         if(body && Open[i] < val)
         {
            flag = false;
            x++;
         }
         if(flag && Close[i] < val) x++;
      }
      
      if(x > brkLimit && brkLimit > 0)
      {
         lastCross = i;
         break;
      }
   }
   
   touchesOut   = t;
   lastCrossOut = lastCross;
}

//+------------------------------------------------------------------+
//| БЛОК 9: СОРТИРОВКА ГОРИЗОНТАЛЬНЫХ КАНДИДАТОВ                     |
//|    Первичный ключ: непробитые (brokenBar==0) идут первыми.       |
//|    Вторичный ключ: меньшее distToPrice — первее.                 |
//+------------------------------------------------------------------+
void SortHorizontals(HorizontalLineCandidate &arr[])
{
   int n = ArraySize(arr);
   // Пузырьковая сортировка: массив небольшой (<50), O(n²) приемлемо
   for(int i = 0; i < n - 1; i++)
   {
      for(int j = 0; j < n - 1 - i; j++)
      {
         bool swap = false;
         bool jAlive  = (arr[j].brokenBar   == 0);
         bool j1Alive = (arr[j+1].brokenBar == 0);
         
         if(!jAlive && j1Alive)
         {
            swap = true;  // Живая вперёд пробитой
         }
         else if(jAlive == j1Alive)
         {
            if(arr[j].distToPrice > arr[j+1].distToPrice) swap = true;
         }
         
         if(swap)
         {
            HorizontalLineCandidate tmp = arr[j];
            arr[j]   = arr[j+1];
            arr[j+1] = tmp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| БЛОК 10: СОРТИРОВКА НАКЛОННЫХ КАНДИДАТОВ                         |
//|    Первичный ключ: непробитые (brokenBar==0) идут первыми.       |
//|    Вторичный ключ: меньший freshness (ближе к bar[0]) — первее.  |
//+------------------------------------------------------------------+
void SortSlopings(SlopingLineCandidate &arr[])
{
   int n = ArraySize(arr);
   for(int i = 0; i < n - 1; i++)
   {
      for(int j = 0; j < n - 1 - i; j++)
      {
         bool swap = false;
         bool jAlive  = (arr[j].brokenBar   == 0);
         bool j1Alive = (arr[j+1].brokenBar == 0);
         
         if(!jAlive && j1Alive)
         {
            swap = true;
         }
         else if(jAlive == j1Alive)
         {
            if(arr[j].freshness > arr[j+1].freshness) swap = true;
         }
         
         if(swap)
         {
            SlopingLineCandidate tmp = arr[j];
            arr[j]   = arr[j+1];
            arr[j+1] = tmp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| БЛОК 11: ОТРИСОВКА — горизонтальная линия                        |
//+------------------------------------------------------------------+
void DrawHorizontalLine(const HorizontalLineCandidate &c)
{
   color  clr       = c.isResistance ? ResColor : SupColor;
   string prefix    = c.isResistance ? "Res"    : "Sup";
   string nameMain  = OBJ_PREFIX + prefix + "@" + IntegerToString(c.fromBar);
   
   // Основная (непробитая часть) линия: от fromBar до brokenBar (или до 0 если не пробита)
   int endIdx = (c.brokenBar > 0) ? c.brokenBar : 0;
   if(ObjectCreate(nameMain, OBJ_TREND, 0, Time[c.fromBar], c.price, Time[endIdx], c.price))
   {
      ObjectSet(nameMain, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSet(nameMain, OBJPROP_COLOR, clr);
      ObjectSet(nameMain, OBJPROP_WIDTH, LineWidth);
      ObjectSet(nameMain, OBJPROP_RAY,   (c.brokenBar == 0));   // Луч только у живых
      ObjectSet(nameMain, OBJPROP_BACK,  true);
   }
   
   // Ценовая подпись (опционально)
   if(g_showPriceLabels)
   {
      string nameText = OBJ_PREFIX + prefix + "Text@" + IntegerToString(c.fromBar);
      double textY = c.isResistance ? c.price + g_textPad : c.price - g_textPad;
      if(ObjectCreate(nameText, OBJ_TEXT, 0, Time[c.fromBar], textY))
      {
         ObjectSetText(nameText,
                       DoubleToStr(c.price, _Digits),
                       LabelFontSize, LabelFontFace, clr);
      }
   }
   
   // Пунктирное продолжение (только если разрешено и линия пробита)
   if(g_showBroken && c.brokenBar > 0)
   {
      string nameBroken = OBJ_PREFIX + "Broken" + prefix + "@" + IntegerToString(c.fromBar);
      if(ObjectCreate(nameBroken, OBJ_TREND, 0, Time[c.brokenBar], c.price, Time[0], c.price))
      {
         ObjectSet(nameBroken, OBJPROP_STYLE, STYLE_DOT);
         ObjectSet(nameBroken, OBJPROP_COLOR, clr);
         ObjectSet(nameBroken, OBJPROP_WIDTH, 1);
         ObjectSet(nameBroken, OBJPROP_RAY,   true);
         ObjectSet(nameBroken, OBJPROP_BACK,  true);
      }
   }
}

//+------------------------------------------------------------------+
//| БЛОК 12: ОТРИСОВКА — наклонная линия                             |
//+------------------------------------------------------------------+
void DrawSlopingLine(const SlopingLineCandidate &c)
{
   color  clr      = c.isResistance ? SlopeResColor : SlopeSupColor;
   string prefix   = c.isResistance ? "SlopeRes"    : "SlopeSup";
   string nameMain = OBJ_PREFIX + prefix + "@" + IntegerToString(c.fromBar) + "_" + IntegerToString(c.toBar);
   
   // Основная часть: от fromBar до xLine (если пробита) или до endLine на bar[0]
   int    endIdx  = (c.brokenBar > 0) ? c.brokenBar : 0;
   double endY    = (c.brokenBar > 0) ? c.xLine     : c.endLine;
   
   if(ObjectCreate(nameMain, OBJ_TREND, 0, Time[c.fromBar], c.priceFrom, Time[endIdx], endY))
   {
      ObjectSet(nameMain, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSet(nameMain, OBJPROP_COLOR, clr);
      ObjectSet(nameMain, OBJPROP_WIDTH, LineWidth);
      ObjectSet(nameMain, OBJPROP_RAY,   (c.brokenBar == 0));
      ObjectSet(nameMain, OBJPROP_BACK,  true);
   }
   
   // Пунктирное продолжение (опционально)
   if(g_showBroken && c.brokenBar > 0)
   {
      string nameBroken = OBJ_PREFIX + "Broken" + prefix + "@" + IntegerToString(c.fromBar) + "_" + IntegerToString(c.toBar);
      if(ObjectCreate(nameBroken, OBJ_TREND, 0, Time[c.brokenBar], c.xLine, Time[0], c.endLine))
      {
         ObjectSet(nameBroken, OBJPROP_STYLE, STYLE_DOT);
         ObjectSet(nameBroken, OBJPROP_COLOR, clr);
         ObjectSet(nameBroken, OBJPROP_WIDTH, 1);
         ObjectSet(nameBroken, OBJPROP_RAY,   true);
         ObjectSet(nameBroken, OBJPROP_BACK,  true);
      }
   }
}

//+------------------------------------------------------------------+
//| БЛОК 13: ОТРИСОВКА — метка swing-точки (символ ^)                |
//+------------------------------------------------------------------+
void DrawSwingLabel(int barIdx, bool isPeak)
{
   string prefix = isPeak ? "Pk" : "Tr";
   color  clr    = isPeak ? ResColor : SupColor;
   double y      = isPeak ? High[barIdx] + g_textPad : Low[barIdx] - g_textPad;
   string name   = OBJ_PREFIX + prefix + "@" + IntegerToString(barIdx);
   
   if(ObjectCreate(name, OBJ_TEXT, 0, Time[barIdx], y))
   {
      ObjectSetText(name, "^", LabelFontSize, LabelFontFace, clr);
   }
}

//+------------------------------------------------------------------+
//| БЛОК 14: УДАЛЕНИЕ ТОЛЬКО СОБСТВЕННЫХ ОБЪЕКТОВ                    |
//|    Критично: оригинал использовал ObjectsDeleteAll(0), который   |
//|    удалял ВСЁ подряд, в т.ч. пользовательские линии/заметки.     |
//+------------------------------------------------------------------+
void DeleteOwnObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   // Идём с конца, чтобы не нарушать индексацию при удалении
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, OBJ_PREFIX) == 0)
         ObjectDelete(name);
   }
}
//+------------------------------------------------------------------+
