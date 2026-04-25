//+------------------------------------------------------------------+
//|                                        L_Liquidity_v3_0.mq4      |
//|  L-Liquidity v3.0: Rolling-Z адаптивный индикатор стресса рынка  |
//|                                  Copyright © 2026, Ruslan Kuchma |
//+------------------------------------------------------------------+
//
//  БЛОК 1: ЗАГОЛОВОК / ТЕХНИЧЕСКОЕ ЗАДАНИЕ
//
//  ИЗМЕНЕНИЯ ПО ОТНОШЕНИЮ К v2.0:
//    1. ИСПРАВЛЕНО: КРИТИЧЕСКИЙ БАГ инверсии α в EMA σ
//         Было:  newSurprise = α * CONST + (1-α) * prev   ← неверно
//         Стало: newSurprise = α * prev + (1-α) * CONST   ← по статье
//    2. ЗАМЕНЕНА: теоретическая нормализация (H1, H2) на ROLLING-Z
//         L = 1 - Φ((σ_curr - mean_K(σ)) / std_K(σ))
//         даёт сбалансированное распределение Blue/Magenta/Red на всех TF
//    3. ИСПРАВЛЕНО: гистограмма с переменной высотой давала пропуски
//         при L=0. Теперь высота ФИКСИРОВАННАЯ = HistogramHeight (1.0),
//         а ЦВЕТ показывает зону. Полоса непрерывная без пропусков.
//    4. УПРОЩЕНО: убрана вся теоретическая часть (H1, H2, NormalCDF
//         используется только для rolling-z, без теоретических констант).
//
//  КОНЦЕПЦИЯ:
//    L измеряет насколько НЕОЖИДАНЕН текущий уровень surprise σ
//    относительно его собственного недавнего поведения (окно K).
//    L ∈ [0, 1]:
//      L >= L_High_Level (0.7) → BLUE  : нормальный режим (торгуй)
//      L 0.3..0.7 → MAGENTA : переходная зона (осторожно)
//      L < L_Low_Level (0.3) → RED    : СТРЕСС (снизь агрессивность)
//    Основа: Alpha Engine event-based entropy + адаптивная Z-нормализация
//
//  МЕТОДОЛОГИЯ:
//    1. Directional Change (DC): цена меняет направление на δ%
//    2. Overshoot (OS): цена продолжает движение на δ% после DC
//    3. δ адаптивная: δ = ATR(N) / Close × Multiplier
//    4. Surprise (EMA, исправленная):
//         σ_new = α · σ_old + (1-α) · const_event
//         const_DC = -log(1 - exp(-2.52579)) ≈ 0.0832
//         const_OS = 2.52579
//         α = exp(-2/(K+1))
//    5. Rolling-Z нормализация:
//         μ_K = mean(σ за K последних баров)
//         s_K = std(σ за K последних баров)
//         z = (σ_curr - μ_K) / s_K
//         L = 1 - Φ(z)        (Φ — нормальная CDF, Abramowitz-Stegun)
//
//  АНТИРЕПЕЙНТ:
//    - Цикл i >= 1 (бар 0 НИКОГДА не рассчитывается)
//    - DC/OS events фиксируются по High[i]/Low[i] закрытых баров
//    - State между барами хранится в служебных буферах
//
//  БУФЕРЫ ДЛЯ EA (iCustom):
//    0 - L_High_Hist  : фикс. высота=H, BLUE столбики (L >= 0.7)
//    1 - L_Mid_Hist   : фикс. высота=H, MAGENTA столбики (0.3..0.7)
//    2 - L_Low_Hist   : фикс. высота=H, RED столбики (L < 0.3)
//    3 - L_Raw        : сырое L ∈ [0, 1] БЕЗ сглаживания (для EA-фильтра)
//    4 - EventType    : (0=нет, +1=DC_Up, -1=DC_Down, +2=OS_Up, -2=OS_Down)
//    5 - DeltaUsed    : используемая δ в долях цены
//
//  ПРИМЕР iCustom (EA-фильтр):
//    double L = iCustom(NULL, 0, "L_Liquidity_v3_0",
//                       14, 2.5, 10,                    // ATR-калибровка
//                       true, 100,                      // K
//                       0.7, 0.3,                       // пороги L
//                       3, 1.0,                         // smooth, height
//                       false, true, false, false, false, "alert.wav",
//                       3, 1);                          // буфер L_Raw, бар 1
//    if(L > 0.5) OpenTrade();
//
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//  БЛОК 2: PROPERTIES
//+------------------------------------------------------------------+
#property copyright "Ruslan Kuchma, 2026"
#property link      "https://t.me/RuslanKuchma"
#property version   "3.00"
#property strict
#property description "L-Liquidity v3.0: ROLLING-Z адаптивный индикатор стресса"
#property description "BLUE=норма, MAGENTA=осторожно, RED=стресс. Высота фиксированная"
#property description "Антирепейнт: бар 0 не рассчитывается. Используй как фильтр для EA"

#property indicator_separate_window
#property indicator_buffers 3
#property indicator_minimum 0.0
#property indicator_maximum 1.0

//--- Буфер 0: L >= 0.7 (норма) ---
#property indicator_label1   "L_High"
#property indicator_type1    DRAW_HISTOGRAM
#property indicator_color1   clrBlue
#property indicator_width1   3

//--- Буфер 1: L 0.3..0.7 (осторожно) ---
#property indicator_label2   "L_Mid"
#property indicator_type2    DRAW_HISTOGRAM
#property indicator_color2   clrMagenta
#property indicator_width2   3

//--- Буфер 2: L < 0.3 (стресс) ---
#property indicator_label3   "L_Low"
#property indicator_type3    DRAW_HISTOGRAM
#property indicator_color3   clrRed
#property indicator_width3   3

//--- Уровни ---
#property indicator_level1   0.3
#property indicator_level2   0.5
#property indicator_level3   0.7
#property indicator_levelcolor clrDimGray
#property indicator_levelstyle STYLE_DOT
#property indicator_levelwidth 1

//+------------------------------------------------------------------+
//  БЛОК 3: ВНЕШНИЕ ПАРАМЕТРЫ
//+------------------------------------------------------------------+

//--- === КАЛИБРОВКА THRESHOLD (ATR-based) === ---
input string  S1               = "=== ATR-калибровка δ ===";
input int     ATR_Period       = 14;     // Период ATR (5-100)
input double  ATR_Multiplier   = 2.5;    // Множитель ATR (1.5-3.5, default 2.5)
input int     MinDeltaPoints   = 10;     // Минимум δ в пунктах (защита от спреда)

//--- === K (ОКНО ROLLING-Z + EMA SURPRISE) === ---
input string  S2               = "=== K окно нормализации ===";
input bool    K_Auto           = true;   // Авто K = 5% от баров (clamp 50..200)
input int     K_Manual         = 100;    // K если K_Auto=false (30-500)

//--- === ПОРОГИ L === ---
input string  S3               = "=== Пороги цветов гистограммы ===";
input double  L_High_Level     = 0.7;    // Граница BLUE зоны (норма)
input double  L_Low_Level      = 0.3;    // Граница RED зоны (стресс)

//--- === ВИЗУАЛИЗАЦИЯ === ---
input string  S4               = "=== Визуализация ===";
input int     L_SmoothPeriod   = 3;      // SMA для гистограммы (1=отключено, 3-5)
input double  HistogramHeight  = 1.0;    // Фиксированная высота столбиков (0.5-1.0)

//--- === АЛЕРТЫ === ---
input string  S5               = "=== Алерты ===";
input bool    AlertOnLowL      = false;   // L пересекает L_Low_Level вниз (стресс)
input bool    AlertOnHighL     = false;  // L пересекает L_High_Level вверх (норма)
input bool    UseSoundAlert    = false;
input bool    UseEmailAlert    = false;
input bool    UsePushAlert     = false;
input string  SoundFile        = "alert.wav";

//+------------------------------------------------------------------+
//  БЛОК 4: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ И БУФЕРЫ
//+------------------------------------------------------------------+

//--- Видимые буферы (фиксированной высоты гистограмма) ---
double L_High_Hist[];          // Буфер 0: BLUE
double L_Mid_Hist[];           // Буфер 1: MAGENTA
double L_Low_Hist[];           // Буфер 2: RED

//--- Скрытые буферы для EA (iCustom) ---
double L_Raw[];                // Буфер 3: сырое L ∈ [0,1] (БЕЗ сглаживания)
double EventType[];            // Буфер 4: тип события (+1/-1/+2/-2/0)
double DeltaUsed[];            // Буфер 5: используемая δ в долях цены

//--- Скрытые state-буферы (между барами) ---
double StateInit[];            // Буфер 6: флаг инициализации
double StateMode[];            // Буфер 7: +1 up, -1 down
double StateExtreme[];         // Буфер 8: экстремум фазы
double StateReference[];       // Буфер 9: опорная цена
double StateSurprise[];        // Буфер 10: σ (используется и для rolling-z)

//--- Константы surprise (один раз в OnInit) ---
double g_ConstSurprise_DC;     // -log(1 - exp(-2.52579))
double g_ConstSurprise_OS;     // 2.52579

//--- Валидированные параметры ---
int    g_K;                    // эффективный K (для α И rolling window)
double g_AlphaWeight;          // exp(-2/(K+1)) — вес ПРОШЛОГО в EMA
int    g_SmoothPeriod;
double g_HistHeight;           // валидированная высота
int    g_MinBars;

//--- Защита алертов ---
datetime g_lastAlertTime = 0;

//+------------------------------------------------------------------+
//  БЛОК 5: OnInit() — ИНИЦИАЛИЗАЦИЯ
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 1. Валидация параметров ---
   if(ATR_Period < 2 || ATR_Period > 500)
   { Alert("L_Liquidity v3.0: ATR_Period в [2, 500]"); return(INIT_PARAMETERS_INCORRECT); }

   if(ATR_Multiplier <= 0.0 || ATR_Multiplier > 20.0)
   { Alert("L_Liquidity v3.0: ATR_Multiplier в (0, 20]"); return(INIT_PARAMETERS_INCORRECT); }

   if(MinDeltaPoints < 0)
   { Alert("L_Liquidity v3.0: MinDeltaPoints >= 0"); return(INIT_PARAMETERS_INCORRECT); }

   if(K_Manual < 30 || K_Manual > 500)
   { Alert("L_Liquidity v3.0: K_Manual в [30, 500]"); return(INIT_PARAMETERS_INCORRECT); }

   if(L_High_Level <= L_Low_Level)
   { Alert("L_Liquidity v3.0: L_High_Level > L_Low_Level"); return(INIT_PARAMETERS_INCORRECT); }

   if(L_High_Level > 1.0 || L_Low_Level < 0.0)
   { Alert("L_Liquidity v3.0: уровни L в [0, 1]"); return(INIT_PARAMETERS_INCORRECT); }

   //--- 2. Константы surprise (DC и OS) ---
   //    P(OS) = exp(-2.52579) ≈ 0.0798, P(DC) = 1 - P(OS)
   //    Surprise DC = -log(P(DC)) ≈ 0.0832
   //    Surprise OS = -log(P(OS)) = 2.52579
   double p_os = MathExp(-2.52579);
   g_ConstSurprise_OS = 2.52579;
   g_ConstSurprise_DC = -MathLog(1.0 - p_os);

   //--- 3. K (стартовое значение, финальное при rates_total) ---
   if(K_Auto)
      g_K = 100;                           // временное
   else
      g_K = K_Manual;
   g_AlphaWeight = MathExp(-2.0 / (g_K + 1.0));   // вес ПРОШЛОГО в EMA

   //--- 4. Сглаживание ---
   g_SmoothPeriod = L_SmoothPeriod;
   if(g_SmoothPeriod < 1) { g_SmoothPeriod = 1;  Print("⚠ L_SmoothPeriod < 1, =1"); }
   if(g_SmoothPeriod > 20){ g_SmoothPeriod = 20; Print("⚠ L_SmoothPeriod > 20, =20"); }

   //--- 5. Высота гистограммы ---
   g_HistHeight = HistogramHeight;
   if(g_HistHeight < 0.1) { g_HistHeight = 0.1; Print("⚠ HistogramHeight < 0.1, =0.1"); }
   if(g_HistHeight > 1.0) { g_HistHeight = 1.0; Print("⚠ HistogramHeight > 1.0, =1.0"); }

   //--- 6. Минимум баров ---
   g_MinBars = ATR_Period + g_K + g_SmoothPeriod + 50;

   //--- 7. Регистрация буферов: 3 видимых + 8 скрытых = 11 ---
   IndicatorBuffers(11);

   SetIndexBuffer(0,  L_High_Hist);
   SetIndexBuffer(1,  L_Mid_Hist);
   SetIndexBuffer(2,  L_Low_Hist);
   SetIndexBuffer(3,  L_Raw);
   SetIndexBuffer(4,  EventType);
   SetIndexBuffer(5,  DeltaUsed);
   SetIndexBuffer(6,  StateInit);
   SetIndexBuffer(7,  StateMode);
   SetIndexBuffer(8,  StateExtreme);
   SetIndexBuffer(9,  StateReference);
   SetIndexBuffer(10, StateSurprise);

   //--- 8. Стили видимых буферов ---
   SetIndexStyle(0, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrBlue);
   SetIndexStyle(1, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrMagenta);
   SetIndexStyle(2, DRAW_HISTOGRAM, STYLE_SOLID, 3, clrRed);

   //--- 9. Скрытые буферы ---
   for(int b = 3; b <= 10; b++)
      SetIndexStyle(b, DRAW_NONE);

   //--- 10. Подписи Data Window ---
   SetIndexLabel(0, "L_High (blue)");
   SetIndexLabel(1, "L_Mid (magenta)");
   SetIndexLabel(2, "L_Low (red)");
   SetIndexLabel(3, "L_Raw");
   SetIndexLabel(4, "EventType");
   SetIndexLabel(5, "Delta");
   for(int b2 = 6; b2 <= 10; b2++)
      SetIndexLabel(b2, NULL);

   //--- 11. Empty value: 0.0 для гистограммы (не EMPTY_VALUE!) ---
   SetIndexEmptyValue(0, 0.0);
   SetIndexEmptyValue(1, 0.0);
   SetIndexEmptyValue(2, 0.0);
   SetIndexEmptyValue(3, 0.0);
   SetIndexEmptyValue(4, 0.0);
   SetIndexEmptyValue(5, 0.0);

   //--- 12. Заголовок ---
   IndicatorShortName(StringFormat("L_Liq v3.0 (ATR%d×%.1f, K=%s, RZ)",
                      ATR_Period, ATR_Multiplier,
                      K_Auto ? "auto" : IntegerToString(K_Manual)));
   IndicatorDigits(3);

   //--- 13. Лог старта ---
   Print("=========================================");
   Print("L_Liquidity v3.0 (ROLLING-Z) запущен:");
   Print("  ATR_Period=", ATR_Period, " ATR_Mult=", DoubleToString(ATR_Multiplier, 2));
   Print("  K=", g_K, " (Auto=", K_Auto, ")");
   Print("  α (вес прошлого)=", DoubleToString(g_AlphaWeight, 5));
   Print("  Surp_DC=", DoubleToString(g_ConstSurprise_DC, 5),
         " Surp_OS=", DoubleToString(g_ConstSurprise_OS, 5));
   Print("  L_SmoothPeriod=", g_SmoothPeriod, " HistHeight=", g_HistHeight);
   Print("  Levels: HIGH=", DoubleToString(L_High_Level, 2),
         " LOW=", DoubleToString(L_Low_Level, 2));
   Print("=========================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//  БЛОК 6: OnCalculate() — ОСНОВНОЙ РАСЧЁТ
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
   //--- Минимум баров ---
   if(rates_total < g_MinBars) return(0);

   //--- Авто-расчёт K при первом вызове ---
   if(K_Auto && prev_calculated == 0)
   {
      int K_new = (int)MathRound(rates_total * 0.05);
      if(K_new < 50)  K_new = 50;
      if(K_new > 200) K_new = 200;
      g_K = K_new;
      g_AlphaWeight = MathExp(-2.0 / (g_K + 1.0));
      g_MinBars = ATR_Period + g_K + g_SmoothPeriod + 50;
      Print("L_Liquidity v3.0: Auto K = ", g_K, " (bars=", rates_total, ")");
   }

   //--- Определение limit ---
   int limit;
   if(prev_calculated == 0)
   {
      limit = rates_total - g_MinBars;
      ArrayInitialize(L_High_Hist,    0.0);
      ArrayInitialize(L_Mid_Hist,     0.0);
      ArrayInitialize(L_Low_Hist,     0.0);
      ArrayInitialize(L_Raw,          0.5);
      ArrayInitialize(EventType,      0.0);
      ArrayInitialize(DeltaUsed,      0.0);
      ArrayInitialize(StateInit,      0.0);
      ArrayInitialize(StateMode,      +1.0);
      ArrayInitialize(StateExtreme,   0.0);
      ArrayInitialize(StateReference, 0.0);
      ArrayInitialize(StateSurprise,  g_ConstSurprise_DC);   // стартовое σ
   }
   else
   {
      limit = rates_total - prev_calculated;
   }

   if(limit < 1) limit = 1;
   if(limit > rates_total - g_MinBars) limit = rates_total - g_MinBars;

   //==================================================================
   // ПРОХОД 1: state, σ, rolling-Z, L_Raw — от старых к новым
   //==================================================================
   for(int i = limit; i >= 1; i--)
   {
      //--- 1. Инициализация state на самом старом баре расчёта ---
      if(i + 1 < rates_total && StateInit[i + 1] < 0.5)
      {
         double initPrice = (high[i + 1] + low[i + 1]) / 2.0;
         StateInit[i + 1]      = 1.0;
         StateMode[i + 1]      = +1.0;
         StateExtreme[i + 1]   = initPrice;
         StateReference[i + 1] = initPrice;
         StateSurprise[i + 1]  = g_ConstSurprise_DC;
      }

      //--- 2. Читаем state от предыдущего бара ---
      double prevMode      = StateMode[i + 1];
      double prevExtreme   = StateExtreme[i + 1];
      double prevReference = StateReference[i + 1];
      double prevSurprise  = StateSurprise[i + 1];

      //--- 3. Вычисляем δ через ATR ---
      double atr = iATR(_Symbol, _Period, ATR_Period, i);
      if(atr <= _Point) atr = _Point * 10.0;
      double closePrice = close[i];
      if(closePrice <= _Point) closePrice = 1.0;
      double delta = (atr / closePrice) * ATR_Multiplier;
      double minDeltaDyn = MinDeltaPoints * _Point / closePrice;
      if(delta < minDeltaDyn) delta = minDeltaDyn;
      DeltaUsed[i] = delta;

      //--- 4. Event detection ---
      double hi = high[i];
      double lo = low[i];
      double newMode      = prevMode;
      double newExtreme   = prevExtreme;
      double newReference = prevReference;
      double newSurprise  = prevSurprise;
      double eventCode    = 0.0;

      if(prevMode > 0.0)
      {
         //--- mode = UP ---
         if(hi > prevExtreme) newExtreme = hi;
         double thOS_Up   = prevReference * (1.0 + delta);
         double thDC_Down = prevReference * (1.0 - delta);

         if(hi >= thOS_Up)
         {
            //--- Up Overshoot ---
            eventCode    = +2.0;
            newReference = newExtreme;
            //--- ИСПРАВЛЕНО: правильное направление весов EMA ---
            newSurprise = g_AlphaWeight * prevSurprise
                        + (1.0 - g_AlphaWeight) * g_ConstSurprise_OS;
         }
         else if(lo <= thDC_Down)
         {
            //--- Directional Change to DOWN ---
            eventCode    = -1.0;
            newMode      = -1.0;
            newExtreme   = lo;
            newReference = lo;
            newSurprise = g_AlphaWeight * prevSurprise
                        + (1.0 - g_AlphaWeight) * g_ConstSurprise_DC;
         }
      }
      else
      {
         //--- mode = DOWN ---
         if(lo < prevExtreme) newExtreme = lo;
         double thOS_Down = prevReference * (1.0 - delta);
         double thDC_Up   = prevReference * (1.0 + delta);

         if(lo <= thOS_Down)
         {
            //--- Down Overshoot ---
            eventCode    = -2.0;
            newReference = newExtreme;
            newSurprise = g_AlphaWeight * prevSurprise
                        + (1.0 - g_AlphaWeight) * g_ConstSurprise_OS;
         }
         else if(hi >= thDC_Up)
         {
            //--- Directional Change to UP ---
            eventCode    = +1.0;
            newMode      = +1.0;
            newExtreme   = hi;
            newReference = hi;
            newSurprise = g_AlphaWeight * prevSurprise
                        + (1.0 - g_AlphaWeight) * g_ConstSurprise_DC;
         }
      }

      //--- 5. Записываем новое state ---
      StateInit[i]      = 1.0;
      StateMode[i]      = newMode;
      StateExtreme[i]   = newExtreme;
      StateReference[i] = newReference;
      StateSurprise[i]  = newSurprise;
      EventType[i]      = eventCode;

      //--- 6. ROLLING-Z нормализация ---
      //    Используем последние K баров σ (включая текущий i).
      //    StateSurprise — массив as-series (большие индексы = старые).
      //    Окно: от i до i + K - 1.
      double sum  = 0.0;
      double sum2 = 0.0;
      int    cnt  = 0;
      for(int k = 0; k < g_K; k++)
      {
         int idx = i + k;
         if(idx >= rates_total) break;
         //--- Учитываем только инициализированные бары ---
         if(StateInit[idx] < 0.5) break;
         double s = StateSurprise[idx];
         sum  += s;
         sum2 += s * s;
         cnt++;
      }

      double L = 0.5;     // default при недостатке данных
      if(cnt >= 10)
      {
         double mean_sigma = sum / cnt;
         double var_sigma  = (sum2 / cnt) - (mean_sigma * mean_sigma);
         if(var_sigma < 0.0) var_sigma = 0.0;          // numerical guard
         double std_sigma = MathSqrt(var_sigma);
         if(std_sigma > 1e-10)
         {
            double z = (newSurprise - mean_sigma) / std_sigma;
            L = 1.0 - NormalCDF(z);
         }
      }

      //--- Clamp [0, 1] ---
      if(L < 0.0) L = 0.0;
      if(L > 1.0) L = 1.0;
      L_Raw[i] = L;
   }

   //==================================================================
   // ПРОХОД 2: сглаживание + распределение по цветам с ФИКСИРОВАННОЙ высотой
   //==================================================================
   for(int j = limit; j >= 1; j--)
   {
      //--- Сглаживание L (только для определения цвета, НЕ для L_Raw) ---
      double L_display = L_Raw[j];
      if(g_SmoothPeriod > 1)
      {
         double sumL = 0.0;
         int    cntL = 0;
         for(int k = 0; k < g_SmoothPeriod; k++)
         {
            int idx = j + k;
            if(idx >= rates_total) break;
            sumL += L_Raw[idx];
            cntL++;
         }
         if(cntL > 0) L_display = sumL / cntL;
      }

      //--- Распределение по цветам с ФИКСИРОВАННОЙ высотой ---
      //    Только ОДИН буфер на баре имеет значение g_HistHeight, остальные = 0.0
      L_High_Hist[j] = 0.0;
      L_Mid_Hist[j]  = 0.0;
      L_Low_Hist[j]  = 0.0;

      if(L_display >= L_High_Level)
         L_High_Hist[j] = g_HistHeight;        // BLUE столбик
      else if(L_display >= L_Low_Level)
         L_Mid_Hist[j] = g_HistHeight;         // MAGENTA столбик
      else
         L_Low_Hist[j] = g_HistHeight;         // RED столбик
   }

   //==================================================================
   // БАР 0 — антирепейнт (НИКОГДА не отображается)
   //==================================================================
   L_High_Hist[0] = 0.0;
   L_Mid_Hist[0]  = 0.0;
   L_Low_Hist[0]  = 0.0;
   L_Raw[0]       = L_Raw[1];          // для EA
   EventType[0]   = 0.0;
   DeltaUsed[0]   = DeltaUsed[1];

   //==================================================================
   // АЛЕРТЫ (только bar[1], только на L_Raw)
   //==================================================================
   if(rates_total > 2)
      CheckAlerts(time[1], L_Raw[1], L_Raw[2]);

   return(rates_total);
}

//+------------------------------------------------------------------+
//  БЛОК 7: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| NormalCDF — нормальная CDF (Abramowitz-Stegun 26.2.17, ~7.5e-8)  |
//+------------------------------------------------------------------+
double NormalCDF(double x)
{
   if(x >  6.0) return(1.0);
   if(x < -6.0) return(0.0);

   double b1 =  0.319381530;
   double b2 = -0.356563782;
   double b3 =  1.781477937;
   double b4 = -1.821255978;
   double b5 =  1.330274429;
   double p0 =  0.2316419;
   double c2 =  0.3989422804;            // 1/sqrt(2π)

   double a = MathAbs(x);
   double t = 1.0 / (1.0 + a * p0);
   double b = c2 * MathExp(-x * x / 2.0);
   double n = ((((b5 * t + b4) * t + b3) * t + b2) * t + b1) * t;
   n = 1.0 - b * n;
   if(x < 0.0) n = 1.0 - n;
   return(n);
}

//+------------------------------------------------------------------+
//| CheckAlerts — алерты на пересечение L_Raw уровней                |
//+------------------------------------------------------------------+
void CheckAlerts(const datetime barTime, const double L_curr, const double L_prev)
{
   if(barTime <= g_lastAlertTime) return;

   string symTF = _Symbol + " " + GetTFName(_Period);
   bool   alertFired = false;
   string msg = "";

   if(AlertOnLowL && L_curr < L_Low_Level && L_prev >= L_Low_Level)
   {
      msg = "L-Liq [" + symTF + "]: ⚠ СТРЕСС! L=" + DoubleToString(L_curr, 3)
          + " пересёк " + DoubleToString(L_Low_Level, 2) + " ↓";
      alertFired = true;
   }
   else if(AlertOnHighL && L_curr > L_High_Level && L_prev <= L_High_Level)
   {
      msg = "L-Liq [" + symTF + "]: ✓ НОРМА. L=" + DoubleToString(L_curr, 3)
          + " пересёк " + DoubleToString(L_High_Level, 2) + " ↑";
      alertFired = true;
   }

   if(alertFired)
   {
      Alert(msg);
      if(UseSoundAlert) PlaySound(SoundFile);
      if(UseEmailAlert) SendMail("L-Liquidity Alert", msg);
      if(UsePushAlert)  SendNotification(msg);
      g_lastAlertTime = barTime;
   }
}

//+------------------------------------------------------------------+
//| GetTFName                                                        |
//+------------------------------------------------------------------+
string GetTFName(const int tf)
{
   switch(tf)
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
      default:         return("TF" + IntegerToString(tf));
   }
}

//+------------------------------------------------------------------+
//  БЛОК 8: OnDeinit() — ДЕИНИЦИАЛИЗАЦИЯ
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("L_Liquidity v3.0 деинициализирован. Код: ", reason);
}
//+------------------------------------------------------------------+
