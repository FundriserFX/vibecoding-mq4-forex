//+------------------------------------------------------------------+
//|                                          Confluentum_SR_v1_0.mq4 |
//|       Confluentum S/R: фрактальные уровни поддержки/сопротивления |
//|                  с 9 таймфреймов на одном графике (M1...MN)      |
//|                                                                  |
//|                                Copyright © 2026, Ruslan Kuchma   |
//|                                          https://t.me/RuslanKuchma|
//+------------------------------------------------------------------+
//|                                                                  |
//| КОНЦЕПЦИЯ                                                        |
//|   Уровень = High/Low бара, который является фракталом по         |
//|   N барам слева И справа, где N = TF_target_minutes / Period().  |
//|   Уровень "продлевается" вправо до появления нового фрактала.    |
//|                                                                  |
//| МЕТОДОЛОГИЯ (база — Kang_Gun "S&R Alert", полностью переработано) |
//|   Resistance: на баре фрактала записывается High[i].             |
//|   Support:    на баре фрактала записывается Low[i].              |
//|   Между фракталами: горизонтальное продление последнего уровня.  |
//|                                                                  |
//| АНТИРЕПЕЙНТ — гибридный режим (StrictNoRepaint)                  |
//|   true:  исторические точки 100% immutable, продление вправо     |
//|          в зоне неподтверждения = EMPTY_VALUE (точка не рисуется,|
//|          появляется только когда подтверждена ai_8 барами справа)|
//|   false: исторические точки immutable, продление вправо =        |
//|          копия последнего подтверждённого уровня (визуально       |
//|          непрерывная линия, технически продление может смениться)|
//|                                                                  |
//| АРХИТЕКТУРА БУФЕРОВ (8 видимых)                                  |
//|   4 Primary таймфрейма по выбору пользователя → 8 буферов:       |
//|     buf 0 = Resistance PrimaryTF1   buf 1 = Support PrimaryTF1   |
//|     buf 2 = Resistance PrimaryTF2   buf 3 = Support PrimaryTF2   |
//|     buf 4 = Resistance PrimaryTF3   buf 5 = Support PrimaryTF3   |
//|     buf 6 = Resistance PrimaryTF4   buf 7 = Support PrimaryTF4   |
//|                                                                  |
//|   Дополнительные ТФ (не входящие в Primary, но включённые        |
//|   через ShowXX) — рисуются через OBJ_TREND стиль STYLE_DOT       |
//|   (визуально идентично точкам, экономично по памяти).            |
//|                                                                  |
//| БУФЕРЫ ДЛЯ EA — пример вызова                                    |
//|   double ResH4 = iCustom(NULL, 0, "Confluentum_SR_v1_0",         |
//|                          /*все input по порядку*/, 4, 1);        |
//|   где 4 = индекс буфера (Resistance PrimaryTF3 если он = H4),    |
//|   1 = shift на закрытый бар (антирепейнт).                       |
//|                                                                  |
//| ПОДПИСИ УРОВНЕЙ                                                  |
//|   Текстовая метка справа от последней точки каждого активного    |
//|   уровня: "H4↑1.27450" (R) или "M15↓1.27210" (S). Включается     |
//|   флагом ShowLabels.                                             |
//+------------------------------------------------------------------+

#property copyright   "Copyright © 2026, Ruslan Kuchma"
#property link        "https://t.me/RuslanKuchma"
#property version     "1.00"
#property strict
#property description "Confluentum S/R — мультитаймфрейм уровни (M1...MN), без репейнта."
#property description "8 буферов для EA через iCustom + объекты для дополнительных ТФ."

//+------------------------------------------------------------------+
//| БЛОК 2: PROPERTIES                                               |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   8

// --- Слоты буферов настраиваются в OnInit() через SetIndexStyle ---
// (не через #property, потому что цвета зависят от выбранных Primary ТФ)
#property indicator_type1   DRAW_ARROW
#property indicator_type2   DRAW_ARROW
#property indicator_type3   DRAW_ARROW
#property indicator_type4   DRAW_ARROW
#property indicator_type5   DRAW_ARROW
#property indicator_type6   DRAW_ARROW
#property indicator_type7   DRAW_ARROW
#property indicator_type8   DRAW_ARROW

//+------------------------------------------------------------------+
//| БЛОК 3: INPUT ПАРАМЕТРЫ                                          |
//+------------------------------------------------------------------+

//--- Основные настройки -------------------------------------------
input string _sep1_           = "=== Конфигурация PrimaryTF (буферы для EA) ===";
input ENUM_TIMEFRAMES PrimaryTF1 = PERIOD_M15;   // Primary TF #1 → буферы 0-1
input ENUM_TIMEFRAMES PrimaryTF2 = PERIOD_H1;    // Primary TF #2 → буферы 2-3
input ENUM_TIMEFRAMES PrimaryTF3 = PERIOD_H4;    // Primary TF #3 → буферы 4-5
input ENUM_TIMEFRAMES PrimaryTF4 = PERIOD_D1;    // Primary TF #4 → буферы 6-7

//--- Включение/выключение отображения по таймфреймам --------------
input string _sep2_ = "=== Отображение таймфреймов ===";
input bool ShowM1  = false;   // Показывать уровни M1
input bool ShowM5  = false;   // Показывать уровни M5
input bool ShowM15 = true;    // Показывать уровни M15
input bool ShowM30 = false;   // Показывать уровни M30
input bool ShowH1  = true;    // Показывать уровни H1
input bool ShowH4  = true;    // Показывать уровни H4
input bool ShowD1  = true;    // Показывать уровни D1
input bool ShowW1  = false;   // Показывать уровни W1
input bool ShowMN  = false;   // Показывать уровни MN

//--- Цветовая палитра (контрастная для белого фона) ---------------
input string _sep3_ = "=== Цвета (белый фон) ===";
input color ColorM1  = clrSlateGray;       // Цвет уровней M1
input color ColorM5  = clrDodgerBlue;      // Цвет уровней M5
input color ColorM15 = clrDarkOrange;      // Цвет уровней M15
input color ColorM30 = clrMediumPurple;    // Цвет уровней M30
input color ColorH1  = clrForestGreen;     // Цвет уровней H1
input color ColorH4  = clrCrimson;         // Цвет уровней H4
input color ColorD1  = clrNavy;            // Цвет уровней D1
input color ColorW1  = clrDarkMagenta;     // Цвет уровней W1
input color ColorMN  = clrBlack;           // Цвет уровней MN

//--- Стиль отображения --------------------------------------------
input string _sep4_           = "=== Стиль отображения ===";
input int    DotWidth         = 2;       // Базовая толщина точек
input bool   ScaleByTF        = true;    // Толщина растёт со старшими ТФ (D1+ +1, W1+ +2)
input bool   ShowLabels       = true;    // Текстовые метки справа от последней точки
input int    LabelFontSize    = 8;       // Размер шрифта меток
input int    LabelOffsetBars  = 3;       // Сдвиг метки вправо (баров от последней точки)

//--- Антирепейнт ---------------------------------------------------
input string _sep5_           = "=== Антирепейнт ===";
input bool   StrictNoRepaint  = true;    // true: точка появляется только после подтверждения; false: продление вправо

//--- Алерты --------------------------------------------------------
input string _sep6_           = "=== Алерты ===";
input bool   AlertOnTouch     = false;    // Алерт при касании цены уровня
input int    AlertToleranceP  = 2;       // Допустимое отклонение для касания (пункты)
input bool   UseSoundAlert    = false;    // Звуковой алерт
input string SoundFile        = "alert.wav";  // Имя звукового файла
input bool   UseEmailAlert    = false;   // Email алерт
input bool   UsePushAlert     = false;   // Push алерт

//+------------------------------------------------------------------+
//| БЛОК 4: ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                    |
//+------------------------------------------------------------------+

//--- 8 видимых буферов (4 Primary × 2) ----------------------------
double Buf_R1[], Buf_S1[];   // PrimaryTF1: Resistance / Support
double Buf_R2[], Buf_S2[];   // PrimaryTF2
double Buf_R3[], Buf_S3[];   // PrimaryTF3
double Buf_R4[], Buf_S4[];   // PrimaryTF4

//--- Описание 9 таймфреймов ---------------------------------------
const int TF_COUNT = 9;
ENUM_TIMEFRAMES g_tfPeriod[9];   // PERIOD_M1, PERIOD_M5, ...
int             g_tfMinutes[9];  // 1, 5, 15, 30, 60, 240, 1440, 10080, 43200
string          g_tfName[9];     // "M1", "M5", ... "MN"
bool            g_tfShow[9];     // флаги ShowXX
color           g_tfColor[9];    // цвета
int             g_tfWidth[9];    // итоговая толщина (с учётом ScaleByTF)

//--- Маппинг ТФ на буфер ------------------------------------------
// g_tfBufR[i] = индекс буфера Resistance для слота ТФ i, или -1 если ТФ не Primary
int g_tfBufR[9];
int g_tfBufS[9];

//--- Состояние для дополнительных ТФ (отрисовка через OBJ_TREND) --
// На каждый ТФ храним последний подтверждённый фрактал (бар/цена/время)
// для построения горизонтального сегмента до следующего фрактала
datetime g_lastResTime[9];   // время бара последнего R-фрактала (0 = нет)
double   g_lastResPrice[9];  // цена последнего R-фрактала
datetime g_lastSupTime[9];
double   g_lastSupPrice[9];

//--- Защита алертов: один на бар ----------------------------------
datetime g_lastAlertBarTime = 0;

//--- Префиксы для имён графических объектов -----------------------
const string OBJ_PREFIX = "ConflSR_";

//--- Валидированный массив Primary ТФ -----------------------------
ENUM_TIMEFRAMES g_primaryTFs[4];

//+------------------------------------------------------------------+
//| БЛОК 5: OnInit() — ИНИЦИАЛИЗАЦИЯ                                 |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 5.1 Заполнение справочников 9 ТФ -------------------------
   g_tfPeriod[0]=PERIOD_M1;  g_tfMinutes[0]=1;     g_tfName[0]="M1";
   g_tfPeriod[1]=PERIOD_M5;  g_tfMinutes[1]=5;     g_tfName[1]="M5";
   g_tfPeriod[2]=PERIOD_M15; g_tfMinutes[2]=15;    g_tfName[2]="M15";
   g_tfPeriod[3]=PERIOD_M30; g_tfMinutes[3]=30;    g_tfName[3]="M30";
   g_tfPeriod[4]=PERIOD_H1;  g_tfMinutes[4]=60;    g_tfName[4]="H1";
   g_tfPeriod[5]=PERIOD_H4;  g_tfMinutes[5]=240;   g_tfName[5]="H4";
   g_tfPeriod[6]=PERIOD_D1;  g_tfMinutes[6]=1440;  g_tfName[6]="D1";
   g_tfPeriod[7]=PERIOD_W1;  g_tfMinutes[7]=10080; g_tfName[7]="W1";
   g_tfPeriod[8]=PERIOD_MN1; g_tfMinutes[8]=43200; g_tfName[8]="MN";

   //--- 5.2 Заполнение флагов Show и цветов ---------------------
   g_tfShow[0]=ShowM1;  g_tfColor[0]=ColorM1;
   g_tfShow[1]=ShowM5;  g_tfColor[1]=ColorM5;
   g_tfShow[2]=ShowM15; g_tfColor[2]=ColorM15;
   g_tfShow[3]=ShowM30; g_tfColor[3]=ColorM30;
   g_tfShow[4]=ShowH1;  g_tfColor[4]=ColorH1;
   g_tfShow[5]=ShowH4;  g_tfColor[5]=ColorH4;
   g_tfShow[6]=ShowD1;  g_tfColor[6]=ColorD1;
   g_tfShow[7]=ShowW1;  g_tfColor[7]=ColorW1;
   g_tfShow[8]=ShowMN;  g_tfColor[8]=ColorMN;

   //--- 5.3 Толщина точек с учётом ScaleByTF --------------------
   int baseW = (int)MathMax(1, MathMin(5, DotWidth));
   for(int i=0; i<TF_COUNT; i++)
   {
      int w = baseW;
      if(ScaleByTF)
      {
         if(g_tfMinutes[i] >= 1440)  w++;   // D1 и старше +1
         if(g_tfMinutes[i] >= 10080) w++;   // W1 и старше +2 (итого +1+1)
      }
      g_tfWidth[i] = (int)MathMin(5, w);
   }

   //--- 5.4 Валидация Primary ТФ (без дубликатов) ---------------
   g_primaryTFs[0] = PrimaryTF1;
   g_primaryTFs[1] = PrimaryTF2;
   g_primaryTFs[2] = PrimaryTF3;
   g_primaryTFs[3] = PrimaryTF4;

   for(int p=0; p<4; p++)
   {
      for(int q=p+1; q<4; q++)
      {
         if(g_primaryTFs[p] == g_primaryTFs[q])
         {
            Print("⚠ PrimaryTF дублируются: TF#", p+1, " и TF#", q+1,
                  " оба = ", PeriodToStr(g_primaryTFs[p]),
                  ". Буфер #", q+1, " не получит данных.");
         }
      }
   }

   //--- 5.5 Маппинг Primary ТФ → индексы буферов ----------------
   ArrayInitialize(g_tfBufR, -1);
   ArrayInitialize(g_tfBufS, -1);
   for(int p=0; p<4; p++)
   {
      int slot = FindTFSlot(g_primaryTFs[p]);
      if(slot < 0)
      {
         Print("⚠ PrimaryTF#", p+1, " = ", PeriodToStr(g_primaryTFs[p]),
               " не входит в стандартный набор M1...MN. Буфер останется пуст.");
         continue;
      }
      // Если уже занят — пропустить (приоритет у первого)
      if(g_tfBufR[slot] < 0)
      {
         g_tfBufR[slot] = p * 2;
         g_tfBufS[slot] = p * 2 + 1;
      }
   }

   //--- 5.6 Привязка буферов и стилей ---------------------------
   SetIndexBuffer(0, Buf_R1); SetIndexBuffer(1, Buf_S1);
   SetIndexBuffer(2, Buf_R2); SetIndexBuffer(3, Buf_S2);
   SetIndexBuffer(4, Buf_R3); SetIndexBuffer(5, Buf_S3);
   SetIndexBuffer(6, Buf_R4); SetIndexBuffer(7, Buf_S4);

   //--- Настройка стиля каждого буфера в зависимости от Primary TF
   for(int p=0; p<4; p++)
   {
      int bufR = p * 2;
      int bufS = p * 2 + 1;
      int slot = FindTFSlot(g_primaryTFs[p]);

      color clr = (slot >= 0) ? g_tfColor[slot] : clrGray;
      int   wdt = (slot >= 0) ? g_tfWidth[slot] : DotWidth;
      string nm = (slot >= 0) ? g_tfName[slot] : "?";

      SetIndexStyle(bufR, DRAW_ARROW, STYLE_DOT, wdt, clr);
      SetIndexArrow(bufR, 158);
      SetIndexLabel(bufR, "Res " + nm);
      SetIndexEmptyValue(bufR, EMPTY_VALUE);

      SetIndexStyle(bufS, DRAW_ARROW, STYLE_DOT, wdt, clr);
      SetIndexArrow(bufS, 158);
      SetIndexLabel(bufS, "Sup " + nm);
      SetIndexEmptyValue(bufS, EMPTY_VALUE);
   }

   //--- 5.7 Инициализация буферов EMPTY_VALUE -------------------
   ArrayInitialize(Buf_R1, EMPTY_VALUE); ArrayInitialize(Buf_S1, EMPTY_VALUE);
   ArrayInitialize(Buf_R2, EMPTY_VALUE); ArrayInitialize(Buf_S2, EMPTY_VALUE);
   ArrayInitialize(Buf_R3, EMPTY_VALUE); ArrayInitialize(Buf_S3, EMPTY_VALUE);
   ArrayInitialize(Buf_R4, EMPTY_VALUE); ArrayInitialize(Buf_S4, EMPTY_VALUE);

   //--- 5.8 Инициализация состояния для дополнительных ТФ -------
   for(int i=0; i<TF_COUNT; i++)
   {
      g_lastResTime[i]  = 0;
      g_lastResPrice[i] = 0.0;
      g_lastSupTime[i]  = 0;
      g_lastSupPrice[i] = 0.0;
   }

   //--- 5.9 Очистка возможных старых объектов от прошлой сессии --
   CleanAllObjects();

   //--- 5.10 IndicatorShortName и точность -----------------------
   IndicatorShortName(StringFormat("Confluentum_SR [%s/%s/%s/%s]",
                      PeriodToStr(g_primaryTFs[0]),
                      PeriodToStr(g_primaryTFs[1]),
                      PeriodToStr(g_primaryTFs[2]),
                      PeriodToStr(g_primaryTFs[3])));
   IndicatorDigits(_Digits);

   //--- 5.11 Лог запуска ----------------------------------------
   Print("─── Confluentum_SR v1.0 запущен ───");
   Print("Текущий ТФ графика: ", PeriodToStr((ENUM_TIMEFRAMES)Period()));
   Print("Primary TF (буферы 0-7): ",
         PeriodToStr(g_primaryTFs[0]), " / ",
         PeriodToStr(g_primaryTFs[1]), " / ",
         PeriodToStr(g_primaryTFs[2]), " / ",
         PeriodToStr(g_primaryTFs[3]));
   Print("Антирепейнт: ", (StrictNoRepaint ? "СТРОГИЙ" : "продление вправо"));
   Print("Алерты: ", (AlertOnTouch ? "вкл" : "выкл"),
         " допуск ", AlertToleranceP, " п.");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| БЛОК 6: OnCalculate() — ОСНОВНОЙ РАСЧЁТ                          |
//+------------------------------------------------------------------+
int OnCalculate(const int       rates_total,
                const int       prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   //--- 6.1 Минимум баров для работы ----------------------------
   if(rates_total < 50) return(0);

   //--- 6.2 Определение зоны пересчёта --------------------------
   // Максимальное N среди всех активных ТФ — расширяем зону пересчёта
   int maxN = 1;
   for(int i=0; i<TF_COUNT; i++)
   {
      if(!g_tfShow[i]) continue;
      int N = g_tfMinutes[i] / Period();
      if(N > maxN) maxN = N;
   }

   int limit;
   if(prev_calculated == 0)
   {
      // Первый запуск — пересчёт всей истории
      limit = rates_total - 1;
      // Очистка буферов на всю историю
      ArrayInitialize(Buf_R1, EMPTY_VALUE); ArrayInitialize(Buf_S1, EMPTY_VALUE);
      ArrayInitialize(Buf_R2, EMPTY_VALUE); ArrayInitialize(Buf_S2, EMPTY_VALUE);
      ArrayInitialize(Buf_R3, EMPTY_VALUE); ArrayInitialize(Buf_S3, EMPTY_VALUE);
      ArrayInitialize(Buf_R4, EMPTY_VALUE); ArrayInitialize(Buf_S4, EMPTY_VALUE);
      // Сброс состояния доп. ТФ
      for(int i=0; i<TF_COUNT; i++)
      {
         g_lastResTime[i]=0; g_lastResPrice[i]=0;
         g_lastSupTime[i]=0; g_lastSupPrice[i]=0;
      }
   }
   else
   {
      // Инкрементальный пересчёт + захват зоны неподтверждения
      limit = rates_total - prev_calculated + maxN + 1;
      if(limit > rates_total - 1) limit = rates_total - 1;
   }

   //--- 6.3 Главный цикл по барам (от старых к свежим) ----------
   // ВАЖНО: индексация массивов time/high/low/close — as-series по умолчанию
   // в OnCalculate MQL4: time[0]=свежий, time[rates_total-1]=самый старый.
   // Используем стандартный обход for(i = limit; i >= 0; i--).
   for(int i = limit; i >= 0; i--)
   {
      //--- Для каждого активного ТФ ---
      for(int t = 0; t < TF_COUNT; t++)
      {
         if(!g_tfShow[t]) continue;
         int N = g_tfMinutes[t] / Period();
         if(N < 1) continue;  // ТФ меньше текущего — невозможно

         //--- 6.3.1 Проверка фрактала на баре i -----------------
         // Подтверждение возможно только когда есть N баров СПРАВА
         // (i >= N) и N баров СЛЕВА (i + N <= rates_total - 1)
         bool canCheck = (i >= N) && (i + N <= rates_total - 1);

         bool isResFractal = false;
         bool isSupFractal = false;
         if(canCheck)
         {
            isResFractal = CheckFractal(true,  N, i, high, low, rates_total);
            isSupFractal = CheckFractal(false, N, i, high, low, rates_total);
         }

         //--- 6.3.2 Запись значений: PRIMARY ТФ → буфер ----------
         int bufR = g_tfBufR[t];
         int bufS = g_tfBufS[t];
         if(bufR >= 0)
         {
            // Resistance
            if(isResFractal)
            {
               WriteBuffer(bufR, i, high[i]);
            }
            else if(canCheck || !StrictNoRepaint)
            {
               // canCheck=false и StrictNoRepaint=true → EMPTY (без репейнта)
               // canCheck=false и StrictNoRepaint=false → копия с i+1 (продление)
               // canCheck=true → подтверждённое продление с i+1
               if(i < rates_total - 1)
               {
                  double prevR = ReadBuffer(bufR, i + 1);
                  if(prevR != EMPTY_VALUE) WriteBuffer(bufR, i, prevR);
                  else                     WriteBuffer(bufR, i, EMPTY_VALUE);
               }
            }
            else
            {
               // Свежие неподтверждённые бары + строгий режим → пусто
               WriteBuffer(bufR, i, EMPTY_VALUE);
            }

            // Support — аналогично
            if(isSupFractal)
            {
               WriteBuffer(bufS, i, low[i]);
            }
            else if(canCheck || !StrictNoRepaint)
            {
               if(i < rates_total - 1)
               {
                  double prevS = ReadBuffer(bufS, i + 1);
                  if(prevS != EMPTY_VALUE) WriteBuffer(bufS, i, prevS);
                  else                     WriteBuffer(bufS, i, EMPTY_VALUE);
               }
            }
            else
            {
               WriteBuffer(bufS, i, EMPTY_VALUE);
            }
         }
         else
         {
            //--- 6.3.3 Запись значений: ДОП. ТФ → объекты OBJ_TREND
            // Только при первом проходе (prev_calculated==0) или
            // когда найден новый фрактал на закрытом баре.
            // На каждом фрактале закрываем предыдущий сегмент и
            // открываем новый.
            if(isResFractal && i >= 1)
            {
               // Завершить предыдущий сегмент R до бара i
               if(g_lastResTime[t] != 0)
               {
                  CreateSegment(t, true,
                                g_lastResTime[t], g_lastResPrice[t],
                                time[i],          g_lastResPrice[t]);
               }
               g_lastResTime[t]  = time[i];
               g_lastResPrice[t] = high[i];
            }
            if(isSupFractal && i >= 1)
            {
               if(g_lastSupTime[t] != 0)
               {
                  CreateSegment(t, false,
                                g_lastSupTime[t], g_lastSupPrice[t],
                                time[i],          g_lastSupPrice[t]);
               }
               g_lastSupTime[t]  = time[i];
               g_lastSupPrice[t] = low[i];
            }
         }
      } // конец цикла по ТФ
   } // конец цикла по барам

   //--- 6.4 Финализация: продление сегментов вправо для доп. ТФ --
   // Для каждого ТФ-не-Primary: рисуем "живой" сегмент от последнего
   // фрактала до текущего бара. Это эквивалент продления буфера.
   datetime curTime = time[0];
   for(int t=0; t<TF_COUNT; t++)
   {
      if(!g_tfShow[t]) continue;
      if(g_tfBufR[t] >= 0) continue; // Primary — обрабатывается через буфер

      if(g_lastResTime[t] != 0)
      {
         UpdateLiveSegment(t, true,  g_lastResTime[t], g_lastResPrice[t], curTime);
      }
      if(g_lastSupTime[t] != 0)
      {
         UpdateLiveSegment(t, false, g_lastSupTime[t], g_lastSupPrice[t], curTime);
      }
   }

   //--- 6.5 Текстовые метки справа от последней точки ------------
   if(ShowLabels)
   {
      UpdateAllLabels(time, high, low, rates_total);
   }

   //--- 6.6 Алерты на касание уровня (только bar[1]) ------------
   if(AlertOnTouch && rates_total >= 2)
   {
      CheckTouchAlerts(time, high, low, close);
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| БЛОК 7: ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ                                  |
//+------------------------------------------------------------------+

//--- 7.1 Проверка фрактала по N барам слева и справа ---------------
// isResistance=true: ищем верхний фрактал (High[i] больше всех соседей)
// isResistance=false: нижний фрактал (Low[i] меньше всех)
// Условия — точно как в оригинале Kang_Gun:
//   Резистанс: High[i+k] > High[i] → не фрактал
//              High[i-k] >= High[i] → не фрактал (>= блокирует равные)
//   Саппорт:   Low[i+k] < Low[i] → не фрактал
//              Low[i-k] <= Low[i] → не фрактал
bool CheckFractal(bool isResistance, int N, int i,
                  const double &high[], const double &low[],
                  int rates_total)
{
   // Проверка границ массива
   if(i - N < 0)               return(false);
   if(i + N > rates_total - 1) return(false);

   for(int k = 1; k <= N; k++)
   {
      if(isResistance)
      {
         if(high[i + k] > high[i])  return(false);  // слева
         if(high[i - k] >= high[i]) return(false);  // справа (строго)
      }
      else
      {
         if(low[i + k] < low[i])    return(false);
         if(low[i - k] <= low[i])   return(false);
      }
   }
   return(true);
}

//--- 7.2 Запись/чтение буфера по индексу ---------------------------
void WriteBuffer(int idx, int bar, double val)
{
   switch(idx)
   {
      case 0: Buf_R1[bar] = val; break;
      case 1: Buf_S1[bar] = val; break;
      case 2: Buf_R2[bar] = val; break;
      case 3: Buf_S2[bar] = val; break;
      case 4: Buf_R3[bar] = val; break;
      case 5: Buf_S3[bar] = val; break;
      case 6: Buf_R4[bar] = val; break;
      case 7: Buf_S4[bar] = val; break;
   }
}

double ReadBuffer(int idx, int bar)
{
   switch(idx)
   {
      case 0: return Buf_R1[bar];
      case 1: return Buf_S1[bar];
      case 2: return Buf_R2[bar];
      case 3: return Buf_S2[bar];
      case 4: return Buf_R3[bar];
      case 5: return Buf_S3[bar];
      case 6: return Buf_R4[bar];
      case 7: return Buf_S4[bar];
   }
   return EMPTY_VALUE;
}

//--- 7.3 Поиск индекса слота ТФ в справочнике ---------------------
int FindTFSlot(ENUM_TIMEFRAMES tf)
{
   for(int i=0; i<TF_COUNT; i++)
   {
      if(g_tfPeriod[i] == tf) return(i);
   }
   return(-1);
}

//--- 7.4 Создание/обновление горизонтального сегмента ------------
// Подтверждённый сегмент: от точки A до точки B, цвет/толщина по ТФ
void CreateSegment(int tfSlot, bool isResistance,
                   datetime t1, double p1, datetime t2, double p2)
{
   string nm = StringFormat("%s%s_%s_%I64d",
                            OBJ_PREFIX,
                            (isResistance ? "R" : "S"),
                            g_tfName[tfSlot],
                            (long)t1);

   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_TREND, 0, t1, p1, t2, p2);
      ObjectSetInteger(0, nm, OBJPROP_COLOR,     g_tfColor[tfSlot]);
      ObjectSetInteger(0, nm, OBJPROP_STYLE,     STYLE_DOT);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH,     g_tfWidth[tfSlot]);
      ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, nm, OBJPROP_BACK,      true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,    true);
   }
   else
   {
      ObjectSetInteger(0, nm, OBJPROP_TIME, 0, t1);
      ObjectSetDouble (0, nm, OBJPROP_PRICE,0, p1);
      ObjectSetInteger(0, nm, OBJPROP_TIME, 1, t2);
      ObjectSetDouble (0, nm, OBJPROP_PRICE,1, p2);
   }
}

//--- 7.5 "Живой" сегмент от последнего фрактала вправо ------------
// Используется специальное имя "live" — обновляется на каждом тике
void UpdateLiveSegment(int tfSlot, bool isResistance,
                       datetime tStart, double price, datetime tEnd)
{
   string nm = StringFormat("%s%s_%s_LIVE",
                            OBJ_PREFIX,
                            (isResistance ? "R" : "S"),
                            g_tfName[tfSlot]);

   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_TREND, 0, tStart, price, tEnd, price);
      ObjectSetInteger(0, nm, OBJPROP_COLOR,     g_tfColor[tfSlot]);
      ObjectSetInteger(0, nm, OBJPROP_STYLE,     STYLE_DOT);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH,     g_tfWidth[tfSlot]);
      ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, nm, OBJPROP_BACK,      true);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,    true);
   }
   else
   {
      ObjectSetInteger(0, nm, OBJPROP_TIME, 0, tStart);
      ObjectSetDouble (0, nm, OBJPROP_PRICE,0, price);
      ObjectSetInteger(0, nm, OBJPROP_TIME, 1, tEnd);
      ObjectSetDouble (0, nm, OBJPROP_PRICE,1, price);
   }
}

//--- 7.6 Текстовые метки справа от последней точки уровня --------
void UpdateAllLabels(const datetime &time[], const double &high[],
                     const double &low[], int rates_total)
{
   datetime labelTime = time[0]
                     + (datetime)(LabelOffsetBars * Period() * 60);

   for(int t=0; t<TF_COUNT; t++)
   {
      if(!g_tfShow[t]) { RemoveLabel(t, true); RemoveLabel(t, false); continue; }

      double resPrice = GetCurrentLevel(t, true,  high, low, rates_total);
      double supPrice = GetCurrentLevel(t, false, high, low, rates_total);

      DrawLabel(t, true,  labelTime, resPrice);
      DrawLabel(t, false, labelTime, supPrice);
   }
}

//--- 7.7 Получить текущий уровень по слоту ТФ --------------------
double GetCurrentLevel(int tfSlot, bool isResistance,
                       const double &high[], const double &low[],
                       int rates_total)
{
   int bufIdx = isResistance ? g_tfBufR[tfSlot] : g_tfBufS[tfSlot];
   if(bufIdx >= 0)
   {
      // Primary: берём из буфера на bar[1] (закрытый)
      double v = ReadBuffer(bufIdx, 1);
      if(v != EMPTY_VALUE) return(v);
      // Если bar[1] пуст (строгий режим, нет подтверждения) —
      // ищем ближайший подтверждённый влево
      for(int b=2; b<rates_total && b<2000; b++)
      {
         double v2 = ReadBuffer(bufIdx, b);
         if(v2 != EMPTY_VALUE) return(v2);
      }
      return(EMPTY_VALUE);
   }
   else
   {
      // Доп. ТФ: берём из состояния
      return(isResistance ? g_lastResPrice[tfSlot] : g_lastSupPrice[tfSlot]);
   }
}

//--- 7.8 Отрисовать одну текстовую метку -------------------------
void DrawLabel(int tfSlot, bool isResistance, datetime t, double price)
{
   string nm = StringFormat("%sLBL_%s_%s",
                            OBJ_PREFIX,
                            (isResistance ? "R" : "S"),
                            g_tfName[tfSlot]);

   if(price == EMPTY_VALUE || price <= 0)
   {
      if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
      return;
   }

   string txt = StringFormat("%s%s%s",
                             g_tfName[tfSlot],
                             (isResistance ? "↑" : "↓"),
                             DoubleToString(price, _Digits));

   if(ObjectFind(0, nm) < 0)
   {
      ObjectCreate(0, nm, OBJ_TEXT, 0, t, price);
      ObjectSetString (0, nm, OBJPROP_TEXT,     txt);
      ObjectSetInteger(0, nm, OBJPROP_COLOR,    g_tfColor[tfSlot]);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, LabelFontSize);
      ObjectSetString (0, nm, OBJPROP_FONT,     "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_ANCHOR,   ANCHOR_LEFT);
      ObjectSetInteger(0, nm, OBJPROP_BACK,     false);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,   true);
   }
   else
   {
      ObjectSetString (0, nm, OBJPROP_TEXT,  txt);
      ObjectSetInteger(0, nm, OBJPROP_TIME,0,t);
      ObjectSetDouble (0, nm, OBJPROP_PRICE,0,price);
   }
}

//--- 7.9 Удалить метку (если ТФ выключен) ------------------------
void RemoveLabel(int tfSlot, bool isResistance)
{
   string nm = StringFormat("%sLBL_%s_%s",
                            OBJ_PREFIX,
                            (isResistance ? "R" : "S"),
                            g_tfName[tfSlot]);
   if(ObjectFind(0, nm) >= 0) ObjectDelete(0, nm);
}

//--- 7.10 Проверка касания цены любого активного уровня ---------
void CheckTouchAlerts(const datetime &time[], const double &high[],
                      const double &low[], const double &close[])
{
   // Алерт только при появлении нового бара
   if(time[1] <= g_lastAlertBarTime) return;

   double tol = AlertToleranceP * _Point;

   for(int t=0; t<TF_COUNT; t++)
   {
      if(!g_tfShow[t]) continue;

      // Текущие уровни (берём с bar[1] для подтверждённого)
      double resP = 0, supP = 0;
      int bufR = g_tfBufR[t];
      int bufS = g_tfBufS[t];

      if(bufR >= 0)      resP = ReadBuffer(bufR, 1);
      else               resP = g_lastResPrice[t];
      if(bufS >= 0)      supP = ReadBuffer(bufS, 1);
      else               supP = g_lastSupPrice[t];

      // Проверка касания: бар[1] коснулся в пределах tol
      if(resP != EMPTY_VALUE && resP > 0)
      {
         if(high[1] >= resP - tol && low[1] <= resP + tol)
         {
            FireAlert(g_tfName[t], "RES", resP);
            g_lastAlertBarTime = time[1];
            return; // один алерт на бар
         }
      }
      if(supP != EMPTY_VALUE && supP > 0)
      {
         if(high[1] >= supP - tol && low[1] <= supP + tol)
         {
            FireAlert(g_tfName[t], "SUP", supP);
            g_lastAlertBarTime = time[1];
            return;
         }
      }
   }
}

//--- 7.11 Отправка алерта по 4 каналам ---------------------------
void FireAlert(string tfName, string sigType, double price)
{
   string msg = StringFormat("Confluentum_SR | %s %s %s касание %s @ %s",
                             _Symbol,
                             PeriodToStr((ENUM_TIMEFRAMES)Period()),
                             tfName, sigType,
                             DoubleToString(price, _Digits));

   Alert(msg);
   if(UseSoundAlert) PlaySound(SoundFile);
   if(UseEmailAlert) SendMail("Confluentum_SR Alert", msg);
   if(UsePushAlert)  SendNotification(msg);
}

//--- 7.12 Очистка всех объектов индикатора -----------------------
void CleanAllObjects()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, OBJ_PREFIX) == 0) ObjectDelete(0, nm);
   }
}

//--- 7.13 Строковое имя таймфрейма -------------------------------
string PeriodToStr(ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN";
   }
   return "?";
}

//+------------------------------------------------------------------+
//| БЛОК 8: OnDeinit() — ДЕИНИЦИАЛИЗАЦИЯ                             |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Удаляем ВСЕ свои объекты при любой причине деинициализации
   // (смена ТФ, смена символа, удаление индикатора, рекомпиляция)
   CleanAllObjects();
   Comment("");
   Print("[Confluentum_SR] деинициализирован. Код: ", reason,
         " | Удалено объектов индикатора.");
}
//+------------------------------------------------------------------+
