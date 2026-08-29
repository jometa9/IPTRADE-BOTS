
#property copyright "IPTRADE COPIER LLC"
#property link      "https://jometa9.github.io/IPTRADE"
#property version   "1.0"
#property description "IPTRADE MetaTrader 4 expert advisor for trade copier IPTRADE"
#property icon      "\\Images\\logo.ico"

#property strict

#define MARKET_ORDER_MAX_AGE_SEC 5
// Grace window during which a just-issued copy-open blocks a duplicate open of the
// same master ticket, even before the broker has surfaced the slave order.
#define COPY_INFLIGHT_GRACE_SEC 30

#include <Bridge/BridgeJson.mqh>

#import "copybridge.dll"
int   InitRestServer(string external_url, int min_port, int max_port);
void  StopRestServer();
int   PollNextCommand(uchar &buffer[], int buffer_len);
int   AckCommand(int command_id, int result_code, string message, string data_json);
int   PushLocalEvent(string json_event);
int   GetAssignedPort();
int   SendReadyNotification(string account_json, int local_port);
void  SetTerminalConnected(int is_connected);
#import

string InpExternalServerUrl   = "";
int    InpPortMin             = 0;
int    InpPortMax             = 0;
int    InpEventCheckIntervalMs = 250;

int      g_bridgePort         = -1;
int      g_timerSeconds       = 1;
uint     g_lastPingTickMs     = 0;

int      g_lastAccountLogin   = 0;
string   g_lastAccountServer  = "";
string   g_effectiveServer    = "";

uchar    g_commandBuffer[];
int      g_commandBufferSize  = 1048576;

int      g_reportedOpenTickets[];
int      g_reportedClosedTickets[];
int      g_partialClosedTickets[];

int    g_lastSnapshotOpenTickets[];      // native tickets in the last EMITTED snapshot

// Snapshot ordering (see mt5 EA for the rationale): as MASTER stamp every snapshot with a
// per-run session + monotonic seq; as SLAVE ignore any snapshot that isn't newer than the
// last applied, so stale / replayed snapshots never drive a close.
long    g_snapSession = 0;
long    g_snapSeq = 0;
long    g_lastSnapSession = 0;
long    g_lastSnapSeq = 0;

// In-flight copy-open guard: master tickets for which we just issued an open but the
// order may not be visible yet. A second trigger for the same ticket (the 5s snapshot
// or the on-connect snapshot replay) must NOT open a duplicate. Expires by time (grace).
int      g_inflightOpenTickets[];
datetime g_inflightOpenTimes[];

struct OrderState {
   int ticket;
   int originalTicket;
   int orderType;
   double price;
   double sl;
   double tp;
   double lots;
};
OrderState g_orderStates[];

struct TicketMap {
   int currentTicket;
   int originalTicket;
};
TicketMap g_ticketMaps[];

struct OrderLifecycleState {
   int orderTicket;
   int lifecycleTicket;
};
OrderLifecycleState g_orderLifecycleStates[];

struct CopierEntry {
   int slaveTicket;
   int masterTicket;
};
CopierEntry g_copierEntries[];
bool g_inSlaveCommand = false;

struct EventQueueItem {
   string eventJson;
   int priority;
};
EventQueueItem g_eventQueue[];
bool g_isProcessingEvent = false;

struct CommandQueueItem {
   string commandJson;
   long commandId;
};
CommandQueueItem g_commandQueue[];
bool g_isProcessingCommand = false;

string ToLowerString(const string str) {
   string result = str;
   StringToLower(result);
   return result;
}

string TrimString(const string str) {
   string result = str;
   StringTrimLeft(result);
   StringTrimRight(result);
   return result;
}

bool IsTerminalConnected() {
   return IsConnected();
}

bool JsonFieldIsNull(const string json, const string key) {
   int pos = BridgeJsonFindKey(json, key);
   if(pos < 0) return false;
   pos = StringFind(json, ":", pos);
   if(pos < 0) return false;
   pos = BridgeJsonSkipWhitespace(json, pos + 1);
   if(pos < 0 || pos >= StringLen(json)) return false;
   string token = StringSubstr(json, pos, 4);
   StringToLower(token);
   return (token == "null");
}

string GetEffectiveServerName() {
   string fallbackServer = AccountServer();
   string iniPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\config\\terminal.ini";
   int handle = FileOpen(iniPath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) {
      return fallbackServer;
   }

   string resolvedServer = "";
   while(!FileIsEnding(handle)) {
      string line = TrimString(FileReadString(handle));
      if(StringLen(line) == 0) continue;

      int commentPos = StringFind(line, ";");
      if(commentPos == 0) continue;
      if(commentPos > 0) {
         line = TrimString(StringSubstr(line, 0, commentPos));
         if(StringLen(line) == 0) continue;
      }

      int eqPos = StringFind(line, "=");
      if(eqPos <= 0) continue;

      string key = ToLowerString(TrimString(StringSubstr(line, 0, eqPos)));
      string value = TrimString(StringSubstr(line, eqPos + 1));
      if((key == "lastscanserver" || key == "lastserver") && StringLen(value) > 0) {
         resolvedServer = value;
         break;
      }
   }

   FileClose(handle);
   if(StringLen(resolvedServer) == 0) return fallbackServer;
   return resolvedServer;
}

void AddAllSymbolsToMarketWatch() {
   int totalSymbols = SymbolsTotal(false);
   int addedCount = 0;
   int errorCount = 0;

   for(int i = 0; i < totalSymbols; i++) {
      string symbolName = SymbolName(i, false);

      if(StringLen(symbolName) == 0) continue;

      bool alreadyVisible = SymbolInfoInteger(symbolName, SYMBOL_SELECT);

      if(!alreadyVisible) {

         if(SymbolSelect(symbolName, true)) {
            addedCount++;
         } else {
            errorCount++;

            if(errorCount <= 5) {
            }
         }
      }
   }
}

void ReconcileInitialState() {
   ArrayResize(g_reportedOpenTickets, 0);
   ArrayResize(g_reportedClosedTickets, 0);
   ArrayResize(g_partialClosedTickets, 0);
   ArrayResize(g_orderStates, 0);
   ArrayResize(g_ticketMaps, 0);
   ArrayResize(g_orderLifecycleStates, 0);
   ArrayResize(g_eventQueue, 0);
   ArrayResize(g_lastSnapshotOpenTickets, 0);   // fresh snapshot baseline for this account
   ArrayResize(g_inflightOpenTickets, 0);
   ArrayResize(g_inflightOpenTimes, 0);
   g_isProcessingEvent = false;
   ArrayResize(g_commandQueue, 0);
   g_isProcessingCommand = false;

   int totalOrders = OrdersTotal();
   int skippedCount = 0;

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ticket = OrderTicket();
      int magic = OrderMagicNumber();

      string comment = OrderComment();
      if(StringLen(comment) > 0 && StringToInteger(comment) == magic && magic > 0) {
         skippedCount++;
         ArrayPush(g_reportedOpenTickets, ticket);
         int lifecycleTicket = ResolveLifecycleTicketForOrder(ticket, comment);
         UpdateOrderState(ticket, OrderOpenPrice(), OrderStopLoss(), OrderTakeProfit(), OrderLots(), lifecycleTicket, OrderType());
      }
   }
}

int OnInit() {
   g_snapSession = (long)TimeGMT();   // unique-per-run id so a master restart is detected
   g_snapSeq = 0;
   g_lastSnapSession = 0;             // slave: fresh sync baseline on (re)load / account change
   g_lastSnapSeq = 0;
   string dllPath = "Libraries\\copybridge.dll";
   int dllHandle = FileOpen(dllPath, FILE_READ|FILE_BIN);
   if(dllHandle != INVALID_HANDLE) {
      FileClose(dllHandle);
   }
   
   ArrayResize(g_commandBuffer, g_commandBufferSize);

   AddAllSymbolsToMarketWatch();

   g_bridgePort = InitRestServer(InpExternalServerUrl, InpPortMin, InpPortMax);

   if(g_bridgePort <= 0) {
      return(INIT_FAILED);
   }

   g_lastAccountLogin  = AccountNumber();
   LoadCopierEntries();
   PurgeStaleCopierEntries();

   ReconcileInitialState();

   g_lastAccountServer = AccountServer();
   g_effectiveServer   = GetEffectiveServerName();

   bool timerSet = EventSetMillisecondTimer(InpEventCheckIntervalMs);
   if(!timerSet) {
      EventSetTimer(1);
   }

   ProcessTradeEvents();

   g_timerSeconds = 1;

   string accountInfo = BuildAccountInfoJson();
   int readyResult = SendReadyNotification(accountInfo, g_bridgePort);
   SetTerminalConnected(IsTerminalConnected() ? 1 : 0);


   g_lastPingTickMs = GetTickCount();

   while(true) {
      int len = PollNextCommand(g_commandBuffer, g_commandBufferSize);
      if(len <= 0) break;
      string json = CharArrayToString(g_commandBuffer, 0, len);
      long oldCmdId = BridgeJsonGetLong(json, "command_id", 0);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   StopRestServer();
}

void ReinitializeForAccountChange(int newLogin, const string newServer) {
   g_lastAccountLogin  = newLogin;
   g_lastAccountServer = newServer;
   g_effectiveServer   = GetEffectiveServerName();

   LoadCopierEntries();
   PurgeStaleCopierEntries();

   ReconcileInitialState();

   string accountInfo = BuildAccountInfoJson();
   SendReadyNotification(accountInfo, g_bridgePort);
   SetTerminalConnected(IsTerminalConnected() ? 1 : 0);

   ProcessTradeEvents();

   while(true) {
      int len = PollNextCommand(g_commandBuffer, g_commandBufferSize);
      if(len <= 0) break;
   }

   g_lastPingTickMs = GetTickCount();
}

void CollectOpenPositionTickets(int &out[]) {
   ArrayResize(out, 0);
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ot = OrderType();
      if(ot != OP_BUY && ot != OP_SELL) continue;
      ArrayPush(out, OrderTicket());
   }
}

bool SnapshotReflectsRealData() {
   if(!IsTerminalConnected()) return false;
   int n = ArraySize(g_lastSnapshotOpenTickets);
   for(int i = 0; i < n; i++) {
      int t = g_lastSnapshotOpenTickets[i];
      if(t <= 0) continue;
      if(OrderSelect(t, SELECT_BY_TICKET)) continue;  // still selectable (open or closed) -> real
      return false;                                    // vanished without trace -> not real yet
   }
   return true;
}

void OnTimer() {

   static int timerCallCount = 0;
   static datetime lastLogTime = 0;
   timerCallCount++;

   SetTerminalConnected(IsTerminalConnected() ? 1 : 0);

   datetime now = TimeCurrent();

   if(now != lastLogTime) {
      lastLogTime = now;
      timerCallCount = 0;
   }

   uint nowTick = GetTickCount();
   bool shouldEmitSnapshot = (nowTick - g_lastPingTickMs >= 5000);
   bool accountChanged = false;
   if(shouldEmitSnapshot) {
      g_lastPingTickMs = nowTick;

      int currentLogin  = AccountNumber();
      string currentServer = AccountServer();
      accountChanged = (currentLogin != g_lastAccountLogin) || (currentServer != g_lastAccountServer);
      if(accountChanged) {
         ReinitializeForAccountChange(currentLogin, currentServer);
      }
   }

   ProcessTradeEvents();
   ProcessEventQueue();
   ProcessIncomingCommands();

   if(shouldEmitSnapshot) {
      if(!accountChanged && SnapshotReflectsRealData()) {
         string snapshotJson = BuildSnapshotEventJson();
         PushLocalEvent(snapshotJson);
         CollectOpenPositionTickets(g_lastSnapshotOpenTickets);
      }
      PurgeStaleCopierEntries();
      PurgeInflightOpens();
   }
}

void OnTrade() {
   ProcessTradeEvents();
   ProcessEventQueue();
}

void ProcessIncomingCommands() {
   while(true) {
      int len = PollNextCommand(g_commandBuffer, g_commandBufferSize);
      if(len <= 0) break;
      
      string json = CharArrayToString(g_commandBuffer, 0, len);
      if(StringLen(json) > 0) {
         long cmdId = BridgeJsonGetLong(json, "command_id", 0);
         QueueCommand(json, cmdId);
      }
   }
   
   ProcessCommandQueue();
}

string ToLowerManual(const string str) {
   string result = str;
   int len = StringLen(result);
   for(int i = 0; i < len; i++) {
      int ch = (int)StringGetCharacter(result, i);
      if(ch >= 'A' && ch <= 'Z') {
         StringSetCharacter(result, i, (int)(ch + 32));
      }
   }
   return result;
}

void SendAckInternal(const long commandId, const int resultCode, const string message, const string data, const int sourceLine) {
   int cmdId32 = (int)commandId;
   if(resultCode < 0) {
      string safeMessage = "Error on line " + IntegerToString(sourceLine);
      string safeData = "{\"success\":false,\"error\":\"" + safeMessage + "\"}";
      AckCommand(cmdId32, resultCode, safeMessage, safeData);
      return;
   }
   AckCommand(cmdId32, resultCode, message, data);
}

#define SendAck(commandId, resultCode, message, data) SendAckInternal(commandId, resultCode, message, data, __LINE__)

void HandleCommand(const string json) {
   if(StringLen(json) == 0) {
      return;
   }

   long commandId = BridgeJsonGetLong(json, "command_id", 0);
   string actionStr = BridgeJsonGetString(json, "action", "");
   string action = ToLowerManual(actionStr);

   string payload = BridgeJsonGetObject(json, "payload");

   if(StringLen(actionStr) == 0) {
      string errorMsg = "empty action field";
      string emptyData = "";
      SendAck(commandId, -1, errorMsg, emptyData);
      return;
   }

   g_inSlaveCommand = true;
   if(action == "create") {
      HandleCreate(commandId, payload);
   } else if(action == "modify") {
      HandleModify(commandId, payload);
   } else if(action == "cancel") {
      HandleCancel(commandId, payload);
   } else if(action == "reconcile_snapshot") {
      HandleReconcileSnapshot(commandId, payload);
   } else {
      string errorMsg = "unknown action: " + action;
      string emptyData = "";
      SendAck(commandId, -1, errorMsg, emptyData);
   }
   g_inSlaveCommand = false;
}

double ValidateAndNormalizeSL_MT4(const string symbol, const double entryPrice, const string side, const double requestedSL) {
   if(requestedSL <= 0) return 0.0;

   double point = MarketInfo(symbol, MODE_POINT);
   if(point <= 0) point = 0.00001;

   int stopsLevel = (int)MarketInfo(symbol, MODE_STOPLEVEL);
   double minDistance = stopsLevel * point;

   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   if(side == "buy") {
      if(requestedSL >= entryPrice) return 0.0;
      double distance = entryPrice - requestedSL;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   } else {
      if(requestedSL <= entryPrice) return 0.0;
      double distance = requestedSL - entryPrice;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   }

   return NormalizeDouble(requestedSL, digits);
}

double ValidateAndNormalizeTP_MT4(const string symbol, const double entryPrice, const string side, const double requestedTP) {
   if(requestedTP <= 0) return 0.0;

   double point = MarketInfo(symbol, MODE_POINT);
   if(point <= 0) point = 0.00001;

   int stopsLevel = (int)MarketInfo(symbol, MODE_STOPLEVEL);
   double minDistance = stopsLevel * point;

   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   if(side == "buy") {
      if(requestedTP <= entryPrice) return 0.0;
      double distance = requestedTP - entryPrice;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   } else {
      if(requestedTP >= entryPrice) return 0.0;
      double distance = entryPrice - requestedTP;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   }

   return NormalizeDouble(requestedTP, digits);
}

double NormalizeVolumeForSymbolMT4(const string symbol, const double requestedVolume) {
   double minLot = MarketInfo(symbol, MODE_MINLOT);
   if(minLot <= 0.0) minLot = 0.01;

   double maxLot = MarketInfo(symbol, MODE_MAXLOT);
   if(maxLot <= 0.0) maxLot = minLot;

   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   if(lotStep <= 0.0) lotStep = minLot;

   double adjusted = MathMax(minLot, requestedVolume);
   adjusted = MathMin(adjusted, maxLot);

   double steps = MathFloor(((adjusted - minLot) / lotStep) + 1e-8);
   double normalized = minLot + (steps * lotStep);

   int lotDecimals = 2;
   if(lotStep > 0) lotDecimals = (int)MathRound(-MathLog10(lotStep));
   if(lotDecimals < 0) lotDecimals = 0;
   if(lotDecimals > 8) lotDecimals = 8;

   normalized = NormalizeDouble(normalized, lotDecimals);
   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;
   return normalized;
}

bool IsInflightOpen(const int masterTicket) {
   if(masterTicket <= 0) return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_inflightOpenTickets); i++) {
      if(g_inflightOpenTickets[i] == masterTicket)
         return (now - g_inflightOpenTimes[i] <= COPY_INFLIGHT_GRACE_SEC);
   }
   return false;
}

void MarkInflightOpen(const int masterTicket) {
   if(masterTicket <= 0) return;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_inflightOpenTickets); i++) {
      if(g_inflightOpenTickets[i] == masterTicket) { g_inflightOpenTimes[i] = now; return; }
   }
   int n = ArraySize(g_inflightOpenTickets);
   ArrayResize(g_inflightOpenTickets, n + 1);
   ArrayResize(g_inflightOpenTimes, n + 1);
   g_inflightOpenTickets[n] = masterTicket;
   g_inflightOpenTimes[n]   = now;
}

void UnmarkInflightOpen(const int masterTicket) {
   for(int i = 0; i < ArraySize(g_inflightOpenTickets); i++) {
      if(g_inflightOpenTickets[i] == masterTicket) {
         int last = ArraySize(g_inflightOpenTickets) - 1;
         g_inflightOpenTickets[i] = g_inflightOpenTickets[last];
         g_inflightOpenTimes[i]   = g_inflightOpenTimes[last];
         ArrayResize(g_inflightOpenTickets, last);
         ArrayResize(g_inflightOpenTimes, last);
         return;
      }
   }
}

void PurgeInflightOpens() {
   datetime now = TimeCurrent();
   for(int i = ArraySize(g_inflightOpenTickets) - 1; i >= 0; i--) {
      if(now - g_inflightOpenTimes[i] > COPY_INFLIGHT_GRACE_SEC) {
         int last = ArraySize(g_inflightOpenTickets) - 1;
         g_inflightOpenTickets[i] = g_inflightOpenTickets[last];
         g_inflightOpenTimes[i]   = g_inflightOpenTimes[last];
         ArrayResize(g_inflightOpenTickets, last);
         ArrayResize(g_inflightOpenTimes, last);
      }
   }
}

void HandleCreate(const long commandId, const string payload) {
   string symbol = BridgeJsonGetString(payload, "symbol", "");
   string typeStr = BridgeJsonGetString(payload, "type", "market");
   string type = ToLowerManual(typeStr);
   string sideStr = BridgeJsonGetString(payload, "side", "buy");
   string side = ToLowerManual(sideStr);
   double volume = BridgeJsonGetDouble(payload, "volume", 0.0);
   double price  = BridgeJsonGetDouble(payload, "price", 0.0);
   double sl     = BridgeJsonGetDouble(payload, "sl", 0.0);
   double tp     = BridgeJsonGetDouble(payload, "tp", 0.0);

   int masterTicket = (int)BridgeJsonGetLong(payload, "ticket", 0);
   bool hasMasterTicket = (masterTicket > 0);

   
   string masterIdStr = IntegerToString(masterTicket);
   if(hasMasterTicket) {
      for(int i = 0; i < OrdersTotal(); i++) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderComment() == masterIdStr || OrderMagicNumber() == masterTicket) {
            SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString(masterTicket) + "}");
            return;
         }
      }
   }

   // Already opening this master ticket and the order just isn't visible yet:
   // ack as success and skip, so a near-simultaneous snapshot can't double the copy.
   if(hasMasterTicket && IsInflightOpen(masterTicket)) {
      SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString(masterTicket) + "}");
      return;
   }

   int magic = hasMasterTicket ? masterTicket : 0;

   bool hasVolumeField = (BridgeJsonFindKey(payload, "volume") >= 0);
   if(symbol == "" || !hasVolumeField) {
      SendAck(commandId, -1, "invalid request", "{\"success\":false,\"error\":\"invalid request\"}");
      return;
   }
   if(!SymbolSelect(symbol, true)) {
      SendAck(commandId, -1, "symbol not available", "{\"success\":false,\"error\":\"symbol not available\"}");
      return;
   }

   volume = NormalizeVolumeForSymbolMT4(symbol, volume);

   double tickSize = MarketInfo(symbol, MODE_POINT);
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);
   double ask = MarketInfo(symbol, MODE_ASK);
   double bid = MarketInfo(symbol, MODE_BID);

   int cmd = OP_BUY;
   double entryPrice = 0.0;
   if(type == "market") {
      long eventAgeSeconds = (long)BridgeJsonGetLong(payload, "age_seconds", -1);
      if(eventAgeSeconds < 0) {
         if(commandId > 0) SendAck(commandId, -1, "age_seconds required for market order", "{\"success\":false,\"error\":\"age_seconds required for market order\"}");
         return;
      }
      if(eventAgeSeconds > MARKET_ORDER_MAX_AGE_SEC) {
         string errMsg = StringFormat("event too old for market order (%d s > %d s)", (int)eventAgeSeconds, MARKET_ORDER_MAX_AGE_SEC);
         if(commandId > 0) SendAck(commandId, -1, errMsg, "{\"success\":false,\"error\":\"" + errMsg + "\"}");
         return;
      }
      cmd = (side == "sell") ? OP_SELL : OP_BUY;
      entryPrice = (cmd == OP_BUY) ? ask : bid;
      price = entryPrice;
   } else if(type == "limit") {

      cmd = (side == "sell") ? OP_SELLLIMIT : OP_BUYLIMIT;
      entryPrice = price;
   } else if(type == "stop" || type == "stop_limit") {

      cmd = (side == "sell") ? OP_SELLSTOP : OP_BUYSTOP;
      entryPrice = price;
      price = entryPrice;
   } else {
      SendAck(commandId, -1, "unsupported order type", "{\"success\":false,\"error\":\"unsupported order type\"}");
      return;
   }

   if(type != "market" && price <= 0) {
      SendAck(commandId, -1, "price required for pending order", "{\"success\":false,\"error\":\"price required for pending order\"}");
      return;
   }

   price = NormalizeDouble(price, digits);

   sl = ValidateAndNormalizeSL_MT4(symbol, entryPrice, side, sl);
   tp = ValidateAndNormalizeTP_MT4(symbol, entryPrice, side, tp);

   string comment = hasMasterTicket ? IntegerToString(masterTicket) : "";

   if(hasMasterTicket) MarkInflightOpen(masterTicket);   // claim the ticket before the (possibly slow) fill
   int ticket = OrderSend(symbol, cmd, volume, price, 20, sl, tp, comment, magic, 0, clrNONE);
   if(ticket > 0) {
      int lifecycleTicket = hasMasterTicket ? masterTicket : ticket;
      RegisterTicketMap(ticket, lifecycleTicket);
      SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString(lifecycleTicket) + "}");
   } else {
      if(hasMasterTicket) UnmarkInflightOpen(masterTicket);   // open failed -> release so a later snapshot can retry
      int errorCode = GetLastError();
      string errorMsg = StringFormat("OrderSend failed (error=%d)", errorCode);
      SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
   }
}

void HandleModify(const long commandId, const string payload) {
   int masterTicket = (int)BridgeJsonGetLong(payload, "ticket", 0);

   if(masterTicket <= 0) {
      SendAck(commandId, -1, "ticket is required", "{\"success\":false,\"error\":\"ticket is required\"}");
      return;
   }

   
   int ticket = ResolveMasterToOpenTicket(masterTicket);
   if(ticket <= 0) {
      int candidate = masterTicket;
      for(int chain = 0; chain < 20; chain++) {
         if(!OrderSelect(candidate, SELECT_BY_TICKET, MODE_TRADES)) break;
         string candComment = OrderComment();
         int child = ExtractChildTicketFromComment(candComment);
         if(child > 0 && child != candidate) {
            candidate = child;
         } else {
            ticket = candidate;
            break;
         }
      }
   }
   int initialResolvedTicket = ticket;
   if(ticket <= 0) {
      SendAck(commandId, -1, "ticket not found", "{\"success\":false,\"error\":\"ticket not found\"}");
      return;
   }
   
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
      SendAck(commandId, -1, "ticket select failed", "{\"success\":false,\"error\":\"ticket select failed\"}");
      return;
   }

   int type = OrderType();
   double price = OrderOpenPrice();
   double sl = OrderStopLoss();
   double tp = OrderTakeProfit();
   double currentVolume = OrderLots();
   datetime expiration = OrderExpiration();
   string symbol = OrderSymbol();
   int magic = OrderMagicNumber();
   string comment = OrderComment();
   int digits = (int)MarketInfo(symbol, MODE_DIGITS);

   bool slRequested = false;
   bool tpRequested = false;
   bool slNullRequested = false;
   bool tpNullRequested = false;
   string currentSide = "";
   if(type == OP_BUY || type == OP_BUYLIMIT || type == OP_BUYSTOP) currentSide = "buy";
   else currentSide = "sell";
   if(BridgeJsonFindKey(payload, "sl") >= 0) {
      slRequested = true;
      bool isSlNull = JsonFieldIsNull(payload, "sl");
      double newSL = isSlNull ? 0.0 : BridgeJsonGetDouble(payload, "sl", 0.0);
      if(isSlNull || newSL <= 0) {
         sl = 0.0;
         slNullRequested = true;
      } else {
         double validatedSL = ValidateAndNormalizeSL_MT4(symbol, price, currentSide, newSL);
         if(validatedSL > 0) sl = validatedSL;
      }
   }
   if(BridgeJsonFindKey(payload, "tp") >= 0) {
      tpRequested = true;
      bool isTpNull = JsonFieldIsNull(payload, "tp");
      double newTP = isTpNull ? 0.0 : BridgeJsonGetDouble(payload, "tp", 0.0);
      if(isTpNull || newTP <= 0) {
         tp = 0.0;
         tpNullRequested = true;
      } else {
         double validatedTP = ValidateAndNormalizeTP_MT4(symbol, price, currentSide, newTP);
         if(validatedTP > 0) tp = validatedTP;
      }
   }
   bool stopsUpdateRequested = (slRequested || tpRequested);
   if(type > OP_SELL) {
      if(BridgeJsonFindKey(payload, "price") >= 0) {
         double newPrice = BridgeJsonGetDouble(payload, "price", price);
         price = NormalizeDouble(newPrice, digits);
      }
   }

   bool volumeChangeRequested = false;
   double newVolume = currentVolume;
   bool volumeRequested = (BridgeJsonFindKey(payload, "volume") >= 0);
   if(volumeRequested) {
      newVolume = BridgeJsonGetDouble(payload, "volume", currentVolume);
      newVolume = NormalizeVolumeForSymbolMT4(symbol, newVolume);
      double curVolNorm = NormalizeVolumeForSymbolMT4(symbol, currentVolume);
      if(MathAbs(newVolume - curVolNorm) > 0.00001) {
         volumeChangeRequested = true;
      }
   }

   
   if((type == OP_BUY || type == OP_SELL) && volumeChangeRequested && newVolume <= 0) {
      volumeChangeRequested = false;
   }

   
   if((type == OP_BUY || type == OP_SELL) &&
      !volumeChangeRequested &&
      volumeRequested &&
      newVolume > 0) {
      int altTicket = 0;
      double altVolume = 0.0;
      for(int i = 0; i < OrdersTotal(); i++) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         int candTicket = OrderTicket();
         if(candTicket <= 0) continue;
         if(OrderType() != type || OrderSymbol() != symbol) continue;
         string candComment = OrderComment();
         int candLifecycle = ResolveLifecycleTicketForOrder(candTicket, candComment);
         bool belongs = (candTicket == masterTicket) ||
                        (OrderMagicNumber() == masterTicket) ||
                        (candLifecycle == masterTicket) ||
                        (GetOriginalTicket(candTicket) == masterTicket) ||
                        OrderBelongsToMaster(masterTicket);
         if(!belongs) continue;
         double candLots = OrderLots();
         if(candLots <= newVolume + 0.00001) continue;
         if(altTicket == 0 || candLots < altVolume || (MathAbs(candLots - altVolume) <= 0.00001 && candTicket > altTicket)) {
            altTicket = candTicket;
            altVolume = candLots;
         }
      }
      if(altTicket > 0 && OrderSelect(altTicket, SELECT_BY_TICKET)) {
         ticket = altTicket;
         currentVolume = OrderLots();
         price = OrderOpenPrice();
         expiration = OrderExpiration();
         symbol = OrderSymbol();
         magic = OrderMagicNumber();
         comment = OrderComment();
         if(!slRequested) sl = OrderStopLoss();
         if(!tpRequested) tp = OrderTakeProfit();
         double curVolNormAlt = NormalizeVolumeForSymbolMT4(symbol, currentVolume);
         if(MathAbs(newVolume - curVolNormAlt) > 0.00001 && newVolume < currentVolume) {
            volumeChangeRequested = true;
         }
      }
   }

   if(volumeChangeRequested && (type == OP_BUY || type == OP_SELL)) {
      if(newVolume < currentVolume) {
         double closeVolume = currentVolume - newVolume;
         double closePrice = (type == OP_BUY) ? MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
         if(stopsUpdateRequested) {
            bool preModOk = false;
            if(OrderSelect(ticket, SELECT_BY_TICKET)) {
               double preEntry = OrderOpenPrice();
               double preSl = ValidateAndNormalizeSL_MT4(symbol, preEntry, (type == OP_BUY) ? "buy" : "sell", sl);
               double preTp = ValidateAndNormalizeTP_MT4(symbol, preEntry, (type == OP_BUY) ? "buy" : "sell", tp);
               preModOk = OrderModify(ticket, preEntry, preSl, preTp, expiration, clrNONE);
            }
            if(preModOk) {
            } else {
               GetLastError();
            }
         }
         bool ok = OrderClose(ticket, closeVolume, closePrice, 20, clrNONE);
         if(ok) {
            int remainingTicket = 0;
            double remainingDiff = 999999.0;
            string masterIdStr = IntegerToString(masterTicket);
            for(int attempt = 0; attempt < 5; attempt++) {
               for(int i = 0; i < OrdersTotal(); i++) {
                  if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
                     int candTicket = OrderTicket();
                     if(candTicket <= 0) continue;
                     if(OrderType() != type || OrderSymbol() != symbol) continue;
                     string candComment = OrderComment();
                     int candMagic = OrderMagicNumber();
                     int lifecycleCand = ResolveLifecycleTicketForOrder(candTicket, candComment);
                     bool belongs = (candTicket == masterTicket) ||
                                    (GetOriginalTicket(candTicket) == masterTicket) ||
                                    (lifecycleCand == masterTicket) ||
                                    (candMagic == masterTicket) ||
                                    (candComment == masterIdStr);
                     if(!belongs) continue;
                     double candVol = OrderLots();
                     double candDiff = MathAbs(candVol - newVolume);
                     if(remainingTicket == 0 || candDiff < remainingDiff ||
                        (MathAbs(candDiff - remainingDiff) < 0.00001 && candTicket > remainingTicket)) {
                        remainingTicket = candTicket;
                        remainingDiff = candDiff;
                     }
                  }
               }
               if(remainingTicket > 0) break;
               Sleep(200);
            }
            if(remainingTicket == 0 && OrderSelect(ticket, SELECT_BY_TICKET)) {
               remainingTicket = ticket;
            }
            if(remainingTicket > 0 && remainingTicket != ticket) {
               RegisterTicketMap(remainingTicket, masterTicket);
            }
            if(remainingTicket > 0 && stopsUpdateRequested) {
               bool modOk = false;
               if(OrderSelect(remainingTicket, SELECT_BY_TICKET)) {
                  double remEntry = OrderOpenPrice();
                  double remSl = ValidateAndNormalizeSL_MT4(symbol, remEntry, (type == OP_BUY) ? "buy" : "sell", sl);
                  double remTp = ValidateAndNormalizeTP_MT4(symbol, remEntry, (type == OP_BUY) ? "buy" : "sell", tp);
                  modOk = OrderModify(remainingTicket, remEntry, remSl, remTp, 0, clrNONE);
               }
               if(!modOk) {
                  GetLastError();
               }
            }
            SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
         } else {
            int errorCode = GetLastError();
            string errorMsg = StringFormat("Partial close failed (error=%d)", errorCode);
            SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
         }
         return;
      } else {
         SendAck(commandId, -1, "volume increase not supported for open positions", "{\"success\":false,\"error\":\"volume increase not supported for open positions\"}");
         return;
      }
   }

   if(volumeChangeRequested && type > OP_SELL) {

      string side = "";
      if(type == OP_BUYLIMIT || type == OP_BUYSTOP) {
         side = "buy";
      } else {
         side = "sell";
      }

      double validatedSL = ValidateAndNormalizeSL_MT4(symbol, price, side, sl);
      double validatedTP = ValidateAndNormalizeTP_MT4(symbol, price, side, tp);

      newVolume = NormalizeVolumeForSymbolMT4(symbol, newVolume);

      double origPrice = OrderOpenPrice();
      double origSL = OrderStopLoss();
      double origTP = OrderTakeProfit();
      double origVolume = OrderLots();
      datetime origExpiration = OrderExpiration();
      if(slRequested && !slNullRequested && validatedSL <= 0.0 && origSL > 0.0) validatedSL = origSL;
      if(tpRequested && !tpNullRequested && validatedTP <= 0.0 && origTP > 0.0) validatedTP = origTP;

      bool deleteOk = OrderDelete(ticket);
      if(!deleteOk) {
         int errorCode = GetLastError();
         string errorMsg = StringFormat("Failed to delete pending order (error=%d)", errorCode);
         SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
         return;
      }

      int newTicket = OrderSend(symbol, type, newVolume, price, 20, validatedSL, validatedTP, comment, magic, expiration, clrNONE);
      if(newTicket > 0) {

         RegisterTicketMap(newTicket, masterTicket);

         RemoveOrderState(ticket);
         UpdateOrderState(newTicket, price, validatedSL, validatedTP, newVolume, masterTicket);

         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else {
         int errorCode = GetLastError();

         int rollbackTicket = OrderSend(symbol, type, origVolume, origPrice, 20, origSL, origTP, comment, magic, origExpiration, clrNONE);
         if(rollbackTicket > 0) {

            RegisterTicketMap(rollbackTicket, masterTicket);
            UpdateOrderState(rollbackTicket, origPrice, origSL, origTP, origVolume, masterTicket);
            string errorMsg = StringFormat("Failed to recreate pending order with new volume (error=%d), original order restored", errorCode);
            SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
         } else {
            int rollbackError = GetLastError();
            string errorMsg = StringFormat("CRITICAL: Failed to recreate pending order (error=%d) AND rollback failed (error=%d). Order lost!", errorCode, rollbackError);
            SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
         }
      }
      return;
   }

   double finalPrice = price;
   double finalSl = sl;
   double finalTp = tp;
   string finalSide = "";
   if(type == OP_BUY || type == OP_BUYLIMIT || type == OP_BUYSTOP) finalSide = "buy";
   else finalSide = "sell";
   if(type == OP_BUY || type == OP_SELL) {
      if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
         SendAck(commandId, -1, "ticket select failed before modify", "{\"success\":false,\"error\":\"ticket select failed before modify\"}");
         return;
      }
      finalPrice = OrderOpenPrice();
   }
   finalSl = ValidateAndNormalizeSL_MT4(symbol, finalPrice, finalSide, sl);
   finalTp = ValidateAndNormalizeTP_MT4(symbol, finalPrice, finalSide, tp);

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
      SendAck(commandId, -1, "ticket select failed before final modify", "{\"success\":false,\"error\":\"ticket select failed before final modify\"}");
      return;
   }
   if(slRequested && !slNullRequested && finalSl <= 0.0) {
      double existingSl = OrderStopLoss();
      if(existingSl > 0.0) finalSl = existingSl;
   }
   if(tpRequested && !tpNullRequested && finalTp <= 0.0) {
      double existingTp = OrderTakeProfit();
      if(existingTp > 0.0) finalTp = existingTp;
   }
   double cmpPoint = MarketInfo(symbol, MODE_POINT);
   if(cmpPoint <= 0) cmpPoint = 0.00001;
   double cmpTol = MathMax(cmpPoint * 0.5, 0.0000001);
   bool samePrice = (MathAbs(finalPrice - OrderOpenPrice()) <= cmpTol);
   bool sameSl = (MathAbs(finalSl - OrderStopLoss()) <= cmpTol);
   bool sameTp = (MathAbs(finalTp - OrderTakeProfit()) <= cmpTol);
   bool sameExp = (expiration == OrderExpiration());
   if(samePrice && sameSl && sameTp && sameExp) {
      SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      return;
   }

   bool ok = OrderModify(ticket, finalPrice, finalSl, finalTp, expiration, clrNONE);
   if(ok) {
      SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
   } else {
      int errorCode = GetLastError();
      if(errorCode == 1) { 
         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
         return;
      }
      string errorMsg = StringFormat("OrderModify failed (error=%d)", errorCode);
      SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
   }
}

void HandleCancel(const long commandId, const string payload) {
   int masterTicket = (int)BridgeJsonGetLong(payload, "ticket", 0);
   double closeVolume = BridgeJsonGetDouble(payload, "close_volume", 0.0);
   if(masterTicket <= 0) {
      SendAck(commandId, -1, "ticket is required", "{\"success\":false,\"error\":\"ticket is required\"}");
      return;
   }

   
   int ticket = 0;
   string masterStr = IntegerToString(masterTicket);

   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderMagicNumber() == masterTicket || OrderComment() == masterStr) {
         int cand = OrderTicket();
         if(cand > ticket) ticket = cand;
      }
   }

   if(ticket <= 0) {
      ticket = ResolveMasterToOpenTicket(masterTicket);
   }

   if(ticket <= 0) {
      if(commandId <= 0) {
         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"noop\":\"ticket not found\"}");
      } else {
         SendAck(commandId, -1, "ticket not found", "{\"success\":false,\"error\":\"ticket not found\"}");
      }
      return;
   }

   if(!OrderSelect(ticket, SELECT_BY_TICKET)) {
      SendAck(commandId, -1, "ticket select failed", "{\"success\":false,\"error\":\"ticket select failed\"}");
      return;
   }
   string originalComment = OrderComment();
   int originalMagic = OrderMagicNumber();
   string posSymbol = OrderSymbol();
   double originalVolume = OrderLots();

   int originalMasterTicket = GetOriginalTicket(ticket);
   if(originalMasterTicket == ticket) {
      int masterFromComment = ExtractParentTicketFromComment(originalComment);
      if(masterFromComment > 0) {
         originalMasterTicket = masterFromComment;
         RegisterTicketMap(ticket, originalMasterTicket);
      } else {
         originalMasterTicket = ticket;
      }
   }

   bool ok = false;
   int type = OrderType();
   string symbol = OrderSymbol();
   double lots = OrderLots();
   bool isPartialClose = (closeVolume > 0 && closeVolume < lots);
   if(closeVolume <= 0 || closeVolume > lots) closeVolume = lots;

   if(type == OP_BUY || type == OP_SELL) {
      double price = (type == OP_BUY) ? MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
      ok = OrderClose(ticket, closeVolume, price, 20, clrNONE);
   } else {
      ok = OrderDelete(ticket);
   }

   if(ok) {
      if(isPartialClose && (type == OP_BUY || type == OP_SELL)) {
         double calculatedRemainingVolume = originalVolume - closeVolume;

         int foundTicket = 0;
         double remainingVolume = 0;
         double currentPrice = (type == OP_BUY) ? MarketInfo(symbol, MODE_BID) : MarketInfo(symbol, MODE_ASK);
         string newComment = "";
         double newPrice = 0;
         double newSL = 0;
         double newTP = 0;
         datetime newOpenTime = 0;

         for(int i = OrdersTotal() - 1; i >= 0; i--) {
            if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
               if(OrderSymbol() == posSymbol && OrderMagicNumber() == originalMagic &&
                  OrderType() == type) {
                  double currentLots = OrderLots();
                  if(currentLots < originalVolume && currentLots > 0 && MathAbs(currentLots - calculatedRemainingVolume) < 0.01) {
                     foundTicket = OrderTicket();
                     remainingVolume = currentLots;
                     newComment = OrderComment();
                     newPrice = OrderOpenPrice();
                     newSL = OrderStopLoss();
                     newTP = OrderTakeProfit();
                     newOpenTime = OrderOpenTime();
                     break;
                  }
               }
            }
         }

         if(foundTicket == 0) {
            if(OrderSelect(ticket, SELECT_BY_TICKET)) {
               if(OrderSymbol() == posSymbol && OrderMagicNumber() == originalMagic &&
                  OrderType() == type) {
                  double currentLots = OrderLots();
                  if(currentLots < originalVolume && currentLots > 0) {
                     foundTicket = ticket;
                     remainingVolume = currentLots;
                     newComment = OrderComment();
                     newPrice = OrderOpenPrice();
                     newSL = OrderStopLoss();
                     newTP = OrderTakeProfit();
                     newOpenTime = OrderOpenTime();
                  }
               }
            }
         }

         if(foundTicket == 0 || remainingVolume <= 0) {
            remainingVolume = calculatedRemainingVolume;
            if(foundTicket == 0) {
               foundTicket = ticket;
            }
            if(OrderSelect(ticket, SELECT_BY_TICKET)) {
               newComment = OrderComment();
               newPrice = OrderOpenPrice();
               newSL = OrderStopLoss();
               newTP = OrderTakeProfit();
               newOpenTime = OrderOpenTime();
            } else {
               newComment = originalComment;
               newPrice = 0;
               newSL = 0;
               newTP = 0;
               newOpenTime = 0;
            }
         }

         if(remainingVolume > 0) {

            int masterFromNewComment = ExtractParentTicketFromComment(newComment);
            int initialMasterTicket = originalMasterTicket;

            if(masterFromNewComment > 0) {
               initialMasterTicket = masterFromNewComment;
            }

            int ultimateMasterTicket = GetUltimateMasterTicket(initialMasterTicket);

            if(foundTicket != ultimateMasterTicket) {
               RegisterTicketMap(foundTicket, ultimateMasterTicket);
            }

            double profit = 0;
            double swap = 0;
            double commission = 0;
            datetime closeTime = TimeCurrent();
            int orderType = OP_BUY;
            string side = "buy";

            if(OrderSelect(ticket, SELECT_BY_TICKET)) {
               orderType = OrderType();
               side = (orderType == OP_SELL || orderType == OP_SELLLIMIT || orderType == OP_SELLSTOP) ? "sell" : "buy";
            }

            int total = OrdersHistoryTotal();
            for(int j = total - 1; j >= 0 && j > total - 200; j--) {
               if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
               if(OrderTicket() == ultimateMasterTicket || OrderTicket() == ticket) {
                  string historyComment = OrderComment();
                  if(StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0) {
                     double historyVolume = OrderLots();
                     if(historyVolume > 0) {
                        double volumeRatio = closeVolume / historyVolume;
                        profit = OrderProfit() * volumeRatio;
                        swap = OrderSwap() * volumeRatio;
                        commission = OrderCommission() * volumeRatio;
                     }
                     closeTime = OrderCloseTime();
                     orderType = OrderType();
                     side = (orderType == OP_SELL || orderType == OP_SELLLIMIT || orderType == OP_SELLSTOP) ? "sell" : "buy";
                     break;
                  }
               }
            }

            string eventJson = BuildModifiedEventJson(ultimateMasterTicket, OrderType(), newPrice, newSL, newTP, remainingVolume);
            QueueEvent(eventJson, 0);

            RemoveOrderState(ticket);

            UpdateOrderState(foundTicket, newPrice, newSL, newTP, remainingVolume, ultimateMasterTicket);

            ArrayPush(g_reportedOpenTickets, foundTicket);
         } else {
         }

         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else if(type > OP_SELL) {
         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else {
         SendAck(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      }
   } else {
      int errorCode = GetLastError();
      string errorMsg = StringFormat("Failed to close/delete (error=%d)", errorCode);
      SendAck(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
   }
}

int GetSnapshotMasterTicket(const string elem) {
   int masterTicket = (int)BridgeJsonGetLong(elem, "ticket", 0);
   if(masterTicket <= 0) masterTicket = (int)BridgeJsonGetLong(elem, "order_id", 0);
   return masterTicket;
}

void HandleReconcileSnapshot(const long commandId, const string payload) {
   if(StringLen(payload) == 0) {
      if(commandId != 0) SendAck(commandId, -1, "empty payload", "{\"success\":false}");
      return;
   }

   // Order gate: ignore stale / out-of-order / replayed snapshots (see mt5 EA).
   long inSession = (long)BridgeJsonGetLong(payload, "session", 0);
   long inSeq     = (long)BridgeJsonGetLong(payload, "seq", 0);
   if(inSession > 0) {
      if(inSession != g_lastSnapSession) {
         g_lastSnapSession = inSession;
         g_lastSnapSeq = inSeq;
      } else if(inSeq <= g_lastSnapSeq) {
         return;   // stale or duplicate snapshot -> ignore entirely
      } else {
         g_lastSnapSeq = inSeq;
      }
   }

   string openPositionsArr = BridgeJsonGetObject(payload, "open_positions");
   string pendingOrdersArr = BridgeJsonGetObject(payload, "pending_orders");
   int nPos = BridgeJsonArrayLength(openPositionsArr);
   int nOrd = BridgeJsonArrayLength(pendingOrdersArr);

   for(int k = 0; k < nPos; k++) {
      string e = BridgeJsonArrayElement(openPositionsArr, k);
      int t = GetSnapshotMasterTicket(e);
      string sym = BridgeJsonGetString(e, "symbol", "");
      string side = BridgeJsonGetString(e, "side", "");
      double vol = BridgeJsonGetDouble(e, "volume", 0);
   }
   for(int k = 0; k < nOrd; k++) {
      string e = BridgeJsonArrayElement(pendingOrdersArr, k);
      int t = GetSnapshotMasterTicket(e);
      string sym = BridgeJsonGetString(e, "symbol", "");
      string typeStr = BridgeJsonGetString(e, "type", "");
      string side = BridgeJsonGetString(e, "side", "");
      double vol = BridgeJsonGetDouble(e, "volume", 0);
      double price = BridgeJsonGetDouble(e, "price", 0);
      if(price <= 0) price = BridgeJsonGetDouble(e, "open_price", 0);
   }


   const long snapCmdId = 0;

   bool snapshotValid = (StringFind(payload, "\"open_positions\"") >= 0 && StringFind(payload, "\"pending_orders\"") >= 0);
   bool snapshotArraysParsed =
      (StringLen(openPositionsArr) >= 2 && StringGetCharacter(openPositionsArr, 0) == '[') &&
      (StringLen(pendingOrdersArr) >= 2 && StringGetCharacter(pendingOrdersArr, 0) == '[');
   long nowUtc = (long)GetCurrentUnixUtc();
   // Snapshot freshness is evaluated per-item via age_seconds on each open_positions/pending_orders entry.

   bool exactMatch = (StringFind(payload, "\"exact_match\":true") >= 0);
   if(exactMatch && snapshotValid && snapshotArraysParsed) {
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderMagicNumber() != 0) continue;
         int xmTicket = OrderTicket();
         int xmType = OrderType();
         string xmSymbol = OrderSymbol();
         double xmLots = OrderLots();
         if(xmType == OP_BUY || xmType == OP_SELL) {
            double xmClosePrice = (xmType == OP_BUY) ? MarketInfo(xmSymbol, MODE_BID) : MarketInfo(xmSymbol, MODE_ASK);
            if(OrderClose(xmTicket, xmLots, xmClosePrice, 20, clrNONE)) {
               RemoveOrderState(xmTicket);
               UnmarkCopierEntry(xmTicket);
            }
         } else if(xmType == OP_BUYLIMIT || xmType == OP_SELLLIMIT || xmType == OP_BUYSTOP || xmType == OP_SELLSTOP) {
            if(OrderDelete(xmTicket)) {
               RemoveOrderState(xmTicket);
               UnmarkCopierEntry(xmTicket);
            }
         }
      }
   }

   int nCuenta = OrdersTotal();
   for(int i = 0; i < nCuenta; i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ticket = OrderTicket();
      int otype = OrderType();
      string osym = OrderSymbol();
      string ocmt = OrderComment();
      int master = GetMasterTicketForCurrentOrder();
      int ult = (master > 0) ? GetUltimateMasterTicket(master) : 0;
      if(ult > 0) master = ult;
   }

   
   
   if(snapshotValid && snapshotArraysParsed) {
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         int type = OrderType();
         if(type != OP_BUYLIMIT && type != OP_SELLLIMIT && type != OP_BUYSTOP && type != OP_SELLSTOP) continue;
         int orderMaster = OrderMagicNumber();
         if(orderMaster <= 0) {
            string ordComment = OrderComment();
            int commentTicket = (int)StringToInteger(ordComment);
            if(StringLen(ordComment) > 0 && commentTicket > 0) {
               orderMaster = commentTicket;
            }
         }
         if(orderMaster <= 0) continue;
         bool inSnapshot = false;
         for(int k = 0; k < nOrd; k++) {
            string e = BridgeJsonArrayElement(pendingOrdersArr, k);
            int snapTicket = GetSnapshotMasterTicket(e);
            if(snapTicket == orderMaster) { inSnapshot = true; break; }
         }
         if(!inSnapshot) {
            bool nowOpenInSnapshot = false;
            for(int k = 0; k < nPos; k++) {
               string posElem = BridgeJsonArrayElement(openPositionsArr, k);
               int posMaster = GetSnapshotMasterTicket(posElem);
               if(posMaster == orderMaster) { nowOpenInSnapshot = true; break; }
            }
            if(nowOpenInSnapshot) continue;
            HandleCancel(snapCmdId, "{\"ticket\":" + IntegerToString(orderMaster) + "}");
         }
      }
   }

   
   for(int k = 0; k < nOrd; k++) {
      string elem = BridgeJsonArrayElement(pendingOrdersArr, k);
      int masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket <= 0) continue;

      int slaveTicket = 0;
      for(int i = 0; i < OrdersTotal(); i++) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         int ot = OrderType();
         if(ot != OP_BUYLIMIT && ot != OP_SELLLIMIT && ot != OP_BUYSTOP && ot != OP_SELLSTOP) continue;
         if(OrderBelongsToMaster(masterTicket)) { slaveTicket = OrderTicket(); break; }
         int om = GetMasterTicketForCurrentOrder();
         if(om <= 0) continue;
         int candTicket = OrderTicket();  
         int ult = GetUltimateMasterTicket(om);
         if(ult > 0) om = ult;
         if(om == masterTicket) { slaveTicket = candTicket; break; }
      }

      double snapPrice = BridgeJsonGetDouble(elem, "price", 0);
      if(snapPrice <= 0) snapPrice = BridgeJsonGetDouble(elem, "open_price", 0);
      double snapSl = BridgeJsonGetDouble(elem, "sl", 0);
      double snapTp = BridgeJsonGetDouble(elem, "tp", 0);
      double snapVol = BridgeJsonGetDouble(elem, "volume", 0);
      string typeStr = ToLowerManual(BridgeJsonGetString(elem, "type", "limit"));
      string symbol = BridgeJsonGetString(elem, "symbol", "");
      string side = ToLowerManual(BridgeJsonGetString(elem, "side", "buy"));
      if(symbol == "" || snapVol <= 0 || (typeStr != "limit" && typeStr != "stop") || snapPrice <= 0) {
         continue;
      }

      if(slaveTicket == 0) {
         
         bool havePosition = false;
         for(int i = 0; i < OrdersTotal(); i++) {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
            if(OrderBelongsToMaster(masterTicket)) { havePosition = true; break; }
            int om = GetMasterTicketForCurrentOrder();
            if(om <= 0) continue;
            int ult = GetUltimateMasterTicket(om);
            if(ult > 0) om = ult;
            if(om == masterTicket) { havePosition = true; break; }
         }
         if(!havePosition) {
            string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":" + BridgeJsonQuote(symbol) + ",\"type\":" + BridgeJsonQuote(typeStr) + ",\"side\":" + BridgeJsonQuote(side) + ",\"volume\":" + DoubleToString(snapVol, 2) + ",\"price\":" + DoubleToString(snapPrice, 5) + ",\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + "}";
            HandleCreate(snapCmdId, createPayload);
         }
         continue;
      }

      if(!OrderSelect(slaveTicket, SELECT_BY_TICKET)) continue;
      double curPrice = OrderOpenPrice();
      double curSl = OrderStopLoss();
      double curTp = OrderTakeProfit();
      double curVol = OrderLots();
      string sym = OrderSymbol();
      int ordType = OrderType();
      int snapOrdType = -1;
      if(typeStr == "limit") snapOrdType = (side == "sell") ? OP_SELLLIMIT : OP_BUYLIMIT;
      else if(typeStr == "stop") snapOrdType = (side == "sell") ? OP_SELLSTOP : OP_BUYSTOP;
      if(snapOrdType < 0) continue;
      double lotStep = MarketInfo(sym, MODE_LOTSTEP);
      if(lotStep <= 0) lotStep = 0.01;
      double newVol = NormalizeVolumeForSymbolMT4(sym, snapVol);
      double curVolNorm = NormalizeVolumeForSymbolMT4(sym, curVol);
      
      double volTolerance = MathMin(lotStep * 0.5, 0.001);
      if(volTolerance <= 0) volTolerance = 0.0001;
      bool volEqual = (MathAbs(newVol - curVolNorm) < volTolerance);
      double point = MarketInfo(sym, MODE_POINT);
      if(point <= 0) point = 0.00001;
      double priceTol = MathMax(point * 2, 0.00001);
      bool priceSlTpEqual = (MathAbs(snapPrice - curPrice) < priceTol && MathAbs(snapSl - curSl) < priceTol && MathAbs(snapTp - curTp) < priceTol);
      bool symbolEqual = (sym == symbol);
      bool typeEqual = (ordType == snapOrdType);
      if(priceSlTpEqual && volEqual && symbolEqual && typeEqual) continue;

      string comment = OrderComment();
      int magic = (int)OrderMagicNumber();
      datetime expiration = OrderExpiration();
      string symbolToUse = symbol;
      double pointSym = MarketInfo(symbolToUse, MODE_POINT);
      if(pointSym <= 0) pointSym = 0.00001;
      int digits = (int)MarketInfo(symbolToUse, MODE_DIGITS);
      snapPrice = NormalizeDouble(snapPrice, digits);
      string sideStr = (snapOrdType == OP_BUYLIMIT || snapOrdType == OP_BUYSTOP) ? "buy" : "sell";
      double validSl = ValidateAndNormalizeSL_MT4(symbolToUse, snapPrice, sideStr, snapSl);
      double validTp = ValidateAndNormalizeTP_MT4(symbolToUse, snapPrice, sideStr, snapTp);
      if(!OrderDelete(slaveTicket)) {
         continue;
      }
      int newTicket = OrderSend(symbolToUse, snapOrdType, newVol, snapPrice, 20, validSl, validTp, comment, magic, expiration, clrNONE);
      if(newTicket > 0) {
         RegisterTicketMap(newTicket, masterTicket);
         RemoveOrderState(slaveTicket);
         UpdateOrderState(newTicket, snapPrice, validSl, validTp, newVol, masterTicket);
      } else {
         if(symbolEqual && typeEqual) {
            OrderSend(sym, ordType, curVol, curPrice, 20, curSl, curTp, comment, magic, expiration, clrNONE);
         }
      }
   }

   
   
   if(snapshotValid && snapshotArraysParsed) {
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         int orderMaster = OrderMagicNumber();
         if(orderMaster <= 0) {
            string ordComment = OrderComment();
            int commentTicket = (int)StringToInteger(ordComment);
            if(StringLen(ordComment) > 0 && commentTicket > 0) {
               orderMaster = commentTicket;
            }
         }
         if(orderMaster <= 0) continue;
         bool inSnapshot = false;
         for(int k = 0; k < nPos; k++) {
            string e = BridgeJsonArrayElement(openPositionsArr, k);
            int snapMaster = GetSnapshotMasterTicket(e);
            if(snapMaster == orderMaster) { inSnapshot = true; break; }
         }
         if(!inSnapshot) {
            bool inPending = false;
            for(int k = 0; k < nOrd; k++) {
               string e = BridgeJsonArrayElement(pendingOrdersArr, k);
               int pt = GetSnapshotMasterTicket(e);
               if(pt == orderMaster) { inPending = true; break; }
            }
            if(!inPending)
            {
               HandleCancel(snapCmdId, "{\"ticket\":" + IntegerToString(orderMaster) + "}");
            }
         }
      }
   }

   if(snapshotValid && snapshotArraysParsed) {
      for(int k = 0; k < nPos; k++) {
         string elem = BridgeJsonArrayElement(openPositionsArr, k);
         int masterTicket = GetSnapshotMasterTicket(elem);
         if(masterTicket <= 0) continue;
         if(ToLowerManual(BridgeJsonGetString(elem, "type", "market")) != "market") continue;
         string snapSymbol = BridgeJsonGetString(elem, "symbol", "");
         string snapSide = ToLowerManual(BridgeJsonGetString(elem, "side", "buy"));
         int snapType = (snapSide == "sell") ? OP_SELL : OP_BUY;
        long posAgeSeconds = (long)BridgeJsonGetLong(elem, "age_seconds", -1);

         for(int i = OrdersTotal() - 1; i >= 0; i--) {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
            if(OrderSymbol() != snapSymbol) continue;
            if(!OrderBelongsToMaster(masterTicket)) continue;
            int localType = OrderType();
            string localSide = (localType == OP_SELL) ? "sell" : "buy";
            if(localSide == snapSide) continue;

            int ticketToClose = OrderTicket();
            double vol = OrderLots();
            double closePrice = (localType == OP_BUY) ? MarketInfo(snapSymbol, MODE_BID) : MarketInfo(snapSymbol, MODE_ASK);
            bool closed = OrderClose(ticketToClose, vol, closePrice, 20, clrNONE);
            if(!closed) continue;

           if(posAgeSeconds >= 0 && posAgeSeconds <= MARKET_ORDER_MAX_AGE_SEC) {
               double volume = BridgeJsonGetDouble(elem, "volume", 0);
               double sl = BridgeJsonGetDouble(elem, "sl", 0);
               double tp = BridgeJsonGetDouble(elem, "tp", 0);
               if(snapSymbol != "" && volume > 0) {
                  string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":" + BridgeJsonQuote(snapSymbol) + ",\"type\":\"market\",\"side\":" + BridgeJsonQuote(snapSide) + ",\"volume\":" + DoubleToString(volume, 2) + ",\"price\":0,\"sl\":" + DoubleToString(sl, 5) + ",\"tp\":" + DoubleToString(tp, 5) + ",\"age_seconds\":" + IntegerToString((int)posAgeSeconds) + "}";
                  HandleCreate(snapCmdId, createPayload);
               }
            }
            break;
         }
      }
   }

   
   for(int k = 0; k < nPos; k++) {
      string elem = BridgeJsonArrayElement(openPositionsArr, k);
      int masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket <= 0) continue;
      bool haveIt = false;
      for(int i = 0; i < OrdersTotal(); i++) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
         if(OrderBelongsToMaster(masterTicket)) { haveIt = true; break; }
      }
      if(haveIt) continue;
      if(ToLowerManual(BridgeJsonGetString(elem, "type", "market")) != "market") continue;
      string symbol = BridgeJsonGetString(elem, "symbol", "");
      string side = ToLowerManual(BridgeJsonGetString(elem, "side", "buy"));
      double volume = BridgeJsonGetDouble(elem, "volume", 0);
      double sl = BridgeJsonGetDouble(elem, "sl", 0);
      double tp = BridgeJsonGetDouble(elem, "tp", 0);
      if(symbol == "" || volume <= 0) continue;
      long posAgeSeconds = (long)BridgeJsonGetLong(elem, "age_seconds", -1);
      if(posAgeSeconds < 0) {
         continue;
      }
      if(posAgeSeconds > MARKET_ORDER_MAX_AGE_SEC) {
         continue;
      }
      string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":" + BridgeJsonQuote(symbol) + ",\"type\":\"market\",\"side\":" + BridgeJsonQuote(side) + ",\"volume\":" + DoubleToString(volume, 2) + ",\"price\":0,\"sl\":" + DoubleToString(sl, 5) + ",\"tp\":" + DoubleToString(tp, 5) + ",\"age_seconds\":" + IntegerToString((int)posAgeSeconds) + "}";
      HandleCreate(snapCmdId, createPayload);
   }

   
   for(int k = 0; k < nPos; k++) {
      string elem = BridgeJsonArrayElement(openPositionsArr, k);
      int masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket <= 0) continue;
      string snapSymbol = BridgeJsonGetString(elem, "symbol", "");
      string side = ToLowerManual(BridgeJsonGetString(elem, "side", "buy"));
      int snapType = (side == "sell") ? OP_SELL : OP_BUY;
      double snapVol = BridgeJsonGetDouble(elem, "volume", 0);
      double snapSl = BridgeJsonGetDouble(elem, "sl", 0);
      double snapTp = BridgeJsonGetDouble(elem, "tp", 0);
      if(snapSymbol == "" || snapVol <= 0) continue;
      double targetVol = NormalizeVolumeForSymbolMT4(snapSymbol, NormalizeDouble(snapVol, 2));

      int workingTicket = GetWorkingTicketForMasterPosition(masterTicket, snapSymbol, snapType);
      if(workingTicket == 0) {
         int anySymbolTicket = GetWorkingTicketForMasterPositionAnySymbol(masterTicket, snapType);
         if(anySymbolTicket <= 0) anySymbolTicket = ResolveMasterToOpenTicket(masterTicket);
         if(anySymbolTicket > 0 && OrderSelect(anySymbolTicket, SELECT_BY_TICKET)) {
            if(OrderSymbol() != snapSymbol) {
               long masterAge = (long)BridgeJsonGetLong(elem, "age_seconds", -1);
               bool closeFailed = false;
               while(true) {
                  int ticketToClose = 0;
                  string symClose = "";
                  double vol = 0.0;

                  int ordTypeToClose = -1;
                  for(int s = OrdersTotal() - 1; s >= 0; s--) {
                     if(!OrderSelect(s, SELECT_BY_POS, MODE_TRADES)) continue;
                     int ordType = OrderType();
                     if(ordType != OP_BUY && ordType != OP_SELL) continue;

                     bool belongs = OrderBelongsToMaster(masterTicket);
                     if(!belongs) {
                        int om = GetMasterTicketForCurrentOrder();
                        if(om > 0) {
                           int ult = GetUltimateMasterTicket(om);
                           if(ult > 0) om = ult;
                        }
                        belongs = (om == masterTicket);
                     }
                     if(!belongs) continue;

                     ticketToClose = OrderTicket();
                     ordTypeToClose = ordType;
                     symClose = OrderSymbol();
                     vol = OrderLots();
                     break;
                  }

                  if(ticketToClose <= 0) break;
                  double closePrice = (ordTypeToClose == OP_BUY) ? MarketInfo(symClose, MODE_BID) : MarketInfo(symClose, MODE_ASK);
                  if(!OrderClose(ticketToClose, vol, closePrice, 20, clrNONE)) {
                     closeFailed = true;
                     break;
                  }
               }

               if(masterAge < 0) {
               } else if(masterAge > MARKET_ORDER_MAX_AGE_SEC) {
               } else if(closeFailed) {
               } else {
                  string sideStr = (snapType == OP_BUY) ? "buy" : "sell";
                  string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":\"" + snapSymbol + "\",\"type\":\"market\",\"side\":\"" + sideStr + "\",\"volume\":" + DoubleToString(snapVol, 2) + ",\"price\":0,\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"age_seconds\":" + IntegerToString((int)masterAge) + "}";
                  HandleCreate(snapCmdId, createPayload);
               }
            } else if(OrderType() != snapType) {
               long masterAge = (long)BridgeJsonGetLong(elem, "age_seconds", -1);
               bool closeFailed = false;
               while(true) {
                  int ticketToClose = 0;
                  string symClose = "";
                  double vol = 0.0;
                  int ordTypeToClose = -1;
                  for(int s = OrdersTotal() - 1; s >= 0; s--) {
                     if(!OrderSelect(s, SELECT_BY_POS, MODE_TRADES)) continue;
                     int ordType = OrderType();
                     if(ordType != OP_BUY && ordType != OP_SELL) continue;
                     bool belongs = OrderBelongsToMaster(masterTicket);
                     if(!belongs) {
                        int om = GetMasterTicketForCurrentOrder();
                        if(om > 0) {
                           int ult = GetUltimateMasterTicket(om);
                           if(ult > 0) om = ult;
                        }
                        belongs = (om == masterTicket);
                     }
                     if(!belongs) continue;
                     ticketToClose = OrderTicket();
                     ordTypeToClose = ordType;
                     symClose = OrderSymbol();
                     vol = OrderLots();
                     break;
                  }
                  if(ticketToClose <= 0) break;
                  double closePrice = (ordTypeToClose == OP_BUY) ? MarketInfo(symClose, MODE_BID) : MarketInfo(symClose, MODE_ASK);
                  if(!OrderClose(ticketToClose, vol, closePrice, 20, clrNONE)) {
                     closeFailed = true;
                     break;
                  }
               }
               if(masterAge < 0) {
               } else if(masterAge > MARKET_ORDER_MAX_AGE_SEC) {
               } else if(closeFailed) {
               } else {
                  string sideStr = (snapType == OP_BUY) ? "buy" : "sell";
                  string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":\"" + snapSymbol + "\",\"type\":\"market\",\"side\":\"" + sideStr + "\",\"volume\":" + DoubleToString(snapVol, 2) + ",\"price\":0,\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"age_seconds\":" + IntegerToString((int)masterAge) + "}";
                  HandleCreate(snapCmdId, createPayload);
               }
            }
         }
         continue;
      }
      if(!OrderSelect(workingTicket, SELECT_BY_TICKET)) continue;
      double curVol = OrderLots();

      double minLot = MarketInfo(snapSymbol, MODE_MINLOT);
      if(minLot <= 0) minLot = 0.01;
      double lotStep = MarketInfo(snapSymbol, MODE_LOTSTEP);
      if(lotStep <= 0) lotStep = 0.01;
      int lotDecimals = (lotStep >= 0.1) ? 1 : 2;
      double tolerance = MathMin(lotStep * 0.5, 0.001);
      if(tolerance <= 0) tolerance = 0.0001;

      
      if(curVol > targetVol + tolerance) {
         double toClose = NormalizeDouble(curVol - targetVol, lotDecimals);
         while(toClose >= minLot) {
            if(!OrderSelect(workingTicket, SELECT_BY_TICKET)) break;
            double foundLots = OrderLots();
            double closeVol = (foundLots <= toClose) ? foundLots : toClose;
            closeVol = MathFloor(closeVol / lotStep) * lotStep;
            closeVol = NormalizeDouble(closeVol, lotDecimals);
            if(closeVol < minLot) {
               if(toClose > 0 && foundLots >= minLot) closeVol = minLot;
               else break;
            }
            if(closeVol > foundLots) closeVol = foundLots;
            double closePrice = (snapType == OP_BUY) ? MarketInfo(snapSymbol, MODE_BID) : MarketInfo(snapSymbol, MODE_ASK);
            bool ok = OrderClose(workingTicket, closeVol, closePrice, 20, clrNONE);
            if(!ok) { break; }
            toClose -= closeVol;
            toClose = NormalizeDouble(toClose, lotDecimals);
            double remainderVol = NormalizeDouble(foundLots - closeVol, lotDecimals);
            if(remainderVol >= minLot) {
               string fromClosed = "from #" + IntegerToString(workingTicket);
               string FROMClosed = "FROM #" + IntegerToString(workingTicket);
               for(int r = 0; r < OrdersTotal(); r++) {
                  if(!OrderSelect(r, SELECT_BY_POS, MODE_TRADES)) continue;
                  if(OrderSymbol() != snapSymbol || OrderType() != snapType || OrderTicket() == workingTicket) continue;
                  if(MathAbs(OrderLots() - remainderVol) >= 0.001) continue;
                  string cmt = OrderComment();
                  if(StringFind(cmt, fromClosed) >= 0 || StringFind(cmt, FROMClosed) >= 0) {
                     RegisterTicketMap(OrderTicket(), masterTicket);
                     break;
                  }
               }
            }
            workingTicket = GetWorkingTicketForMasterPosition(masterTicket, snapSymbol, snapType);
            if(workingTicket == 0) break;
         }
      }
      else if(curVol < targetVol - tolerance) {
         double toAdd = NormalizeDouble(targetVol - curVol, lotDecimals);
         if(toAdd >= minLot) {
            long masterAge = (long)BridgeJsonGetLong(elem, "age_seconds", -1);
            if(masterAge >= 0 && masterAge > MARKET_ORDER_MAX_AGE_SEC) {
            } else {
               string sideStr = (snapType == OP_BUY) ? "buy" : "sell";
               long outAge = (masterAge >= 0) ? masterAge : 0;
               string createPayload = "{\"ticket\":" + IntegerToString(masterTicket) + ",\"symbol\":\"" + snapSymbol + "\",\"type\":\"market\",\"side\":\"" + sideStr + "\",\"volume\":" + DoubleToString(toAdd, lotDecimals) + ",\"price\":0,\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"age_seconds\":" + IntegerToString((int)outAge) + "}";
               HandleCreate(snapCmdId, createPayload);
            }
         }
      }

      
      for(int i = 0; i < OrdersTotal(); i++) {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         int ticket = OrderTicket();
         if(ticket <= 0) continue;
         if(OrderType() != snapType || OrderSymbol() != snapSymbol) continue;
         int om = GetMasterTicketForCurrentOrder();
         if(om <= 0) continue;
         int ult = GetUltimateMasterTicket(om);
         if(ult > 0) om = ult;
         if(om != masterTicket) continue;
         if(!OrderSelect(ticket, SELECT_BY_TICKET)) continue;
         if(MathAbs(OrderStopLoss() - snapSl) >= 0.00001 || MathAbs(OrderTakeProfit() - snapTp) >= 0.00001)
            OrderModify(ticket, OrderOpenPrice(), snapSl, snapTp, 0, clrNONE);
      }
   }

   if(commandId != 0) SendAck(commandId, 0, "ok", "{\"success\":true}");
}

int FindOrderStateIndex(int ticket) {
   int size = ArraySize(g_orderStates);
   for(int i = 0; i < size; i++) {
      if(g_orderStates[i].ticket == ticket) return i;
   }
   return -1;
}

int FindOrderLifecycleStateIndex(const int orderTicket) {
   int size = ArraySize(g_orderLifecycleStates);
   for(int i = 0; i < size; i++) {
      if(g_orderLifecycleStates[i].orderTicket == orderTicket) return i;
   }
   return -1;
}

void SetOrderLifecycleState(const int orderTicket, const int lifecycleTicket) {
   int idx = FindOrderLifecycleStateIndex(orderTicket);
   if(idx < 0) {
      int size = ArraySize(g_orderLifecycleStates);
      ArrayResize(g_orderLifecycleStates, size + 1);
      idx = size;
      g_orderLifecycleStates[idx].orderTicket = orderTicket;
   }
   g_orderLifecycleStates[idx].lifecycleTicket = lifecycleTicket;
}

int GetOriginalTicket(int currentTicket) {
   int size = ArraySize(g_ticketMaps);
   for(int i = 0; i < size; i++) {
      if(g_ticketMaps[i].currentTicket == currentTicket) {
         return g_ticketMaps[i].originalTicket;
      }
   }
   return currentTicket;
}

int GetUltimateMasterTicket(int currentTicket) {
   int visitedTickets[];
   ArrayResize(visitedTickets, 0);
   int ticket = currentTicket;
   int maxIterations = 100;
   int iterations = 0;

   while(iterations < maxIterations) {
      iterations++;

      bool alreadyVisited = false;
      for(int i = 0; i < ArraySize(visitedTickets); i++) {
         if(visitedTickets[i] == ticket) {
            alreadyVisited = true;
            break;
         }
      }
      if(alreadyVisited) {
         break;
      }

      int visitedSize = ArraySize(visitedTickets);
      ArrayResize(visitedTickets, visitedSize + 1);
      visitedTickets[visitedSize] = ticket;

      int mappedTicket = GetOriginalTicket(ticket);
      if(mappedTicket != ticket) {
         ticket = mappedTicket;
         continue;
      }

      
      bool foundOrder = (OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY));
      bool hasParentInComment = false;
      if(foundOrder) {
         string comment = OrderComment();
         int parentFromComment = ExtractParentTicketFromComment(comment);
         if(parentFromComment > 0 && parentFromComment != ticket) {
            ticket = parentFromComment;
            hasParentInComment = true;
         }
      }

      
      if(!hasParentInComment) {
         break;
      }
   }

   if(iterations >= maxIterations) {
   }

   return ticket;
}

string CopierEntriesFilePath() {
   return "IPTRADE\\copier_entries_" + IntegerToString(AccountNumber()) + ".csv";
}

int FindCopierEntryIndex(const int slaveTicket) {
   int size = ArraySize(g_copierEntries);
   for(int i = 0; i < size; i++) {
      if(g_copierEntries[i].slaveTicket == slaveTicket) return i;
   }
   return -1;
}

bool IsCopierEntry(const int slaveTicket) {
   return FindCopierEntryIndex(slaveTicket) >= 0;
}

void SaveCopierEntries() {
   string path = CopierEntriesFilePath();
   int handle = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ';');
   if(handle == INVALID_HANDLE) return;
   int size = ArraySize(g_copierEntries);
   for(int i = 0; i < size; i++) {
      FileWrite(handle, g_copierEntries[i].slaveTicket, g_copierEntries[i].masterTicket);
   }
   FileClose(handle);
}

void MarkCopierEntry(const int slaveTicket, const int masterTicket) {
   if(slaveTicket <= 0 || masterTicket <= 0) return;
   int idx = FindCopierEntryIndex(slaveTicket);
   if(idx >= 0) {
      if(g_copierEntries[idx].masterTicket == masterTicket) return;
      g_copierEntries[idx].masterTicket = masterTicket;
   } else {
      int size = ArraySize(g_copierEntries);
      ArrayResize(g_copierEntries, size + 1);
      g_copierEntries[size].slaveTicket = slaveTicket;
      g_copierEntries[size].masterTicket = masterTicket;
   }
   SaveCopierEntries();
}

void UnmarkCopierEntry(const int slaveTicket) {
   int idx = FindCopierEntryIndex(slaveTicket);
   if(idx < 0) return;
   int size = ArraySize(g_copierEntries);
   for(int i = idx; i < size - 1; i++) {
      g_copierEntries[i] = g_copierEntries[i + 1];
   }
   ArrayResize(g_copierEntries, size - 1);
   SaveCopierEntries();
}

void LoadCopierEntries() {
   ArrayResize(g_copierEntries, 0);
   string path = CopierEntriesFilePath();
   if(!FileIsExist(path)) return;
   int handle = FileOpen(path, FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE, ';');
   if(handle == INVALID_HANDLE) return;
   while(!FileIsEnding(handle)) {
      string slaveStr = FileReadString(handle);
      if(FileIsEnding(handle) && StringLen(slaveStr) == 0) break;
      string masterStr = FileReadString(handle);
      int slaveTicket = (int)StringToInteger(slaveStr);
      int masterTicket = (int)StringToInteger(masterStr);
      if(slaveTicket <= 0 || masterTicket <= 0) continue;
      int existingIdx = FindCopierEntryIndex(slaveTicket);
      if(existingIdx >= 0) {
         g_copierEntries[existingIdx].masterTicket = masterTicket;
      } else {
         int size = ArraySize(g_copierEntries);
         ArrayResize(g_copierEntries, size + 1);
         g_copierEntries[size].slaveTicket = slaveTicket;
         g_copierEntries[size].masterTicket = masterTicket;
      }
   }
   FileClose(handle);
}

void PurgeStaleCopierEntries() {
   int size = ArraySize(g_copierEntries);
   bool changed = false;
   for(int i = size - 1; i >= 0; i--) {
      int st = g_copierEntries[i].slaveTicket;
      bool exists = OrderSelect(st, SELECT_BY_TICKET, MODE_TRADES);
      if(!exists) {
         for(int j = i; j < size - 1; j++) {
            g_copierEntries[j] = g_copierEntries[j + 1];
         }
         size--;
         ArrayResize(g_copierEntries, size);
         changed = true;
      }
   }
   if(changed) SaveCopierEntries();
}

void RegisterTicketMap(int currentTicket, int originalTicket) {
   if(g_inSlaveCommand && currentTicket != originalTicket && currentTicket > 0 && originalTicket > 0) {
      MarkCopierEntry(currentTicket, originalTicket);
   }
   int size = ArraySize(g_ticketMaps);
   for(int i = 0; i < size; i++) {
      if(g_ticketMaps[i].currentTicket == currentTicket) {
         g_ticketMaps[i].originalTicket = originalTicket;
         return;
      }
   }
   ArrayResize(g_ticketMaps, size + 1);
   g_ticketMaps[size].currentTicket = currentTicket;
   g_ticketMaps[size].originalTicket = originalTicket;
}

int ExtractParentTicketFromComment(string comment) {
   int pos = StringFind(comment, "from #");
   if(pos < 0) pos = StringFind(comment, "FROM #");
   if(pos < 0) pos = StringFind(comment, "From #");
   if(pos < 0) pos = StringFind(comment, "fron #");
   if(pos < 0) pos = StringFind(comment, "FRON #");
   if(pos >= 0) {
      string ticketStr = StringSubstr(comment, pos + 6);
      string cleanTicket = "";
      for(int i = 0; i < StringLen(ticketStr); i++) {
         int c = StringGetChar(ticketStr, i);
         if(c >= '0' && c <= '9') {
            cleanTicket += CharToStr((uchar)c);
         } else if(c == ' ' || c == '\t') {
            
            if(StringLen(cleanTicket) > 0) break;
         } else {
            break;
         }
      }
      if(StringLen(cleanTicket) > 0) {
         return (int)StringToInteger(cleanTicket);
      }
   }
   return 0;
}

int ResolveLifecycleTicketForOrder(const int orderTicket, const string orderComment = "") {
   if(orderTicket <= 0) return 0;

   int cacheIdx = FindOrderLifecycleStateIndex(orderTicket);
   if(cacheIdx >= 0 && g_orderLifecycleStates[cacheIdx].lifecycleTicket > 0) {
      return g_orderLifecycleStates[cacheIdx].lifecycleTicket;
   }

   int lifecycleTicket = GetOriginalTicket(orderTicket);
   if(lifecycleTicket <= 0) lifecycleTicket = orderTicket;

   string comment = orderComment;
   if(StringLen(comment) == 0) {
      if(OrderSelect(orderTicket, SELECT_BY_TICKET, MODE_TRADES) || OrderSelect(orderTicket, SELECT_BY_TICKET, MODE_HISTORY)) {
         comment = OrderComment();
      }
   }

   int commentAsTicket = (int)StringToInteger(comment);
   if(StringLen(comment) > 0 && commentAsTicket > 0) {
      lifecycleTicket = commentAsTicket;
   }

   int parentFromComment = ExtractParentTicketFromComment(comment);
   if(parentFromComment > 0 && parentFromComment != orderTicket) {
      int ultimate = GetUltimateMasterTicket(parentFromComment);
      lifecycleTicket = (ultimate > 0) ? ultimate : parentFromComment;
   }

   if(lifecycleTicket <= 0) lifecycleTicket = orderTicket;

   RegisterTicketMap(orderTicket, lifecycleTicket);
   SetOrderLifecycleState(orderTicket, lifecycleTicket);
   return lifecycleTicket;
}

bool OrderBelongsToMaster(int masterTicket) {
   if(masterTicket <= 0) return false;
   string comment = OrderComment();
   string masterStr = IntegerToString(masterTicket);
   if(comment == masterStr) return true;
   if(StringFind(comment, "from #" + masterStr) >= 0) return true;
   if(StringFind(comment, "FROM #" + masterStr) >= 0) return true;
   if(StringFind(comment, "From #" + masterStr) >= 0) return true;
   if(StringFind(comment, "fron #" + masterStr) >= 0) return true;
   if(StringFind(comment, "FRON #" + masterStr) >= 0) return true;
   int fromParent = ExtractParentTicketFromComment(comment);
   if(fromParent > 0 && GetUltimateMasterTicket(fromParent) == masterTicket) return true;
   return false;
}

int ResolveMasterToOpenTicket(int masterTicket) {
   if(masterTicket <= 0) return 0;
   int bestTicket = 0;
   string masterStr = IntegerToString(masterTicket);
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int cand = OrderTicket();
      if(cand <= 0) continue;
      int candMagic = OrderMagicNumber();
      string candComment = OrderComment();
      int resolvedMaster = GetMasterTicketForCurrentOrder();
      int ultimateMaster = (resolvedMaster > 0) ? GetUltimateMasterTicket(resolvedMaster) : 0;
      if(ultimateMaster > 0) resolvedMaster = ultimateMaster;
      int lifecycleCand = ResolveLifecycleTicketForOrder(cand, candComment);
      int mappedCand = GetOriginalTicket(cand);
      int parentFromComment = ExtractParentTicketFromComment(candComment);
      int parentUltimate = (parentFromComment > 0) ? GetUltimateMasterTicket(parentFromComment) : 0;
      bool belongs = (cand == masterTicket) ||
                     (candMagic == masterTicket) ||
                     (candComment == masterStr) ||
                     (StringFind(candComment, "from #" + masterStr) >= 0) ||
                     (StringFind(candComment, "FROM #" + masterStr) >= 0) ||
                     (StringFind(candComment, "From #" + masterStr) >= 0) ||
                     (StringFind(candComment, "fron #" + masterStr) >= 0) ||
                     (StringFind(candComment, "FRON #" + masterStr) >= 0) ||
                     (resolvedMaster == masterTicket) ||
                     (lifecycleCand == masterTicket) ||
                     (mappedCand == masterTicket) ||
                     (parentFromComment == masterTicket) ||
                     (parentUltimate == masterTicket);
      if(!belongs) continue;

      if(cand > bestTicket) bestTicket = cand;
   }
   if(bestTicket > 0) RegisterTicketMap(bestTicket, masterTicket);
   return bestTicket;
}

int GetWorkingTicketForMasterPosition(int masterTicket, string symbol, int orderType) {
   if(masterTicket <= 0) return 0;
   int bestTicket = 0;
   int count = 0;
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ticket = OrderTicket();
      if(ticket <= 0) continue;
      if(OrderType() != orderType || OrderSymbol() != symbol) continue;
      int om = GetMasterTicketForCurrentOrder();
      if(om <= 0) continue;
      int ult = GetUltimateMasterTicket(om);
      if(ult > 0) om = ult;
      if(om != masterTicket) continue;
      count++;
      if(ticket > bestTicket) bestTicket = ticket;
   }
   if(count == 0) return 0;
   if(bestTicket > 0 && count > 1) RegisterTicketMap(bestTicket, masterTicket);
   return bestTicket;
}

int GetWorkingTicketForMasterPositionAnySymbol(int masterTicket, int orderType) {
   if(masterTicket <= 0) return 0;
   int bestTicket = 0;
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderType() != orderType) continue;
      int om = GetMasterTicketForCurrentOrder();
      if(om <= 0) continue;
      int ult = GetUltimateMasterTicket(om);
      if(ult > 0) om = ult;
      if(om != masterTicket) continue;
      int ticket = OrderTicket();
      if(ticket > bestTicket) bestTicket = ticket;
   }
   return bestTicket;
}

int GetMasterTicketForCurrentOrder() {
   string comment = OrderComment();
   if(StringLen(comment) > 0) {
      int fromParent = ExtractParentTicketFromComment(comment);
      if(fromParent > 0) {
         int ultimate = GetUltimateMasterTicket(fromParent);
         if(ultimate > 0) return ultimate;
         int orig = GetOriginalTicket(fromParent);
         if(orig > 0) return orig;
         return fromParent;
      }
      int asInt = (int)StringToInteger(comment);
      if(asInt > 0) return asInt;
   }
   int magic = (int)OrderMagicNumber();
   if(magic > 0) return magic;
   return 0;
}

int ExtractChildTicketFromComment(string comment) {
   int pos = StringFind(comment, "to #");
   if(pos < 0) pos = StringFind(comment, "TO #");
   if(pos >= 0) {
      string ticketStr = StringSubstr(comment, pos + 4);
      string cleanTicket = "";
      for(int i = 0; i < StringLen(ticketStr); i++) {
         int c = StringGetChar(ticketStr, i);
         if(c >= '0' && c <= '9') {
            cleanTicket += CharToStr((uchar)c);
         } else {
            break;
         }
      }
      if(StringLen(cleanTicket) > 0) {
         return (int)StringToInteger(cleanTicket);
      }
   }
   return 0;
}

bool SelectOrderByMagicAndComment(int magic, string masterOrderId) {
   if(magic == 0 && masterOrderId == "") {
      return false;
   }

   for(int i = 0; i < OrdersTotal(); i++) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         bool magicMatch = (magic == 0) || (OrderMagicNumber() == magic);
         bool commentMatch = (masterOrderId == "") || (OrderComment() == masterOrderId);

         if(magicMatch && commentMatch) {
            int orderTicket = OrderTicket();
            return true;
         }
      }
   }

   return false;
}

bool SelectOrderByTicket(int ticket) {
   if(OrderSelect(ticket, SELECT_BY_TICKET)) {
      
      
      if(OrderCloseTime() > 0) {
         for(int i = 0; i < OrdersTotal(); i++) {
            if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
            string comment = OrderComment();
            if(StringFind(comment, "from #" + IntegerToString(ticket)) >= 0 ||
               StringFind(comment, "FROM #" + IntegerToString(ticket)) >= 0) {
               int childTicket = OrderTicket();
               RegisterTicketMap(childTicket, ticket);
               return true;
            }
         }
         return false;
      }
      return true;
   }

   int originalTicket = GetOriginalTicket(ticket);
   if(originalTicket != ticket) {
      for(int i = 0; i < OrdersTotal(); i++) {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
            int currentTicket = OrderTicket();
            if(GetOriginalTicket(currentTicket) == originalTicket) {
               return true;
            }
         }
      }
   }

   for(int i = 0; i < OrdersTotal(); i++) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         string comment = OrderComment();
         if(StringFind(comment, "from #" + IntegerToString(ticket)) >= 0 ||
            StringFind(comment, "FROM #" + IntegerToString(ticket)) >= 0) {
            int newTicket = OrderTicket();
            RegisterTicketMap(newTicket, ticket);
            return true;
         }
      }
   }

   for(int i = 0; i < OrdersTotal(); i++) {
      if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) {
         if(OrderTicket() == ticket) {
            return true;
         }
      }
   }

   return false;
}

void UpdateOrderState(int ticket, double price, double sl, double tp, double lots, int originalTicket = 0, int orderType = -1) {
   int idx = FindOrderStateIndex(ticket);
   if(idx < 0) {
      int size = ArraySize(g_orderStates);
      ArrayResize(g_orderStates, size + 1);
      idx = size;
      g_orderStates[idx].ticket = ticket;
   }
   g_orderStates[idx].price = price;
   g_orderStates[idx].sl = sl;
   g_orderStates[idx].tp = tp;
   g_orderStates[idx].lots = lots;
   g_orderStates[idx].originalTicket = (originalTicket > 0) ? originalTicket : ticket;
   if(orderType >= 0) g_orderStates[idx].orderType = orderType;
}

void RemoveOrderState(int ticket) {
   int idx = FindOrderStateIndex(ticket);
   if(idx >= 0) {
      int size = ArraySize(g_orderStates);
      for(int i = idx; i < size - 1; i++) {
         g_orderStates[i] = g_orderStates[i + 1];
      }
      ArrayResize(g_orderStates, size - 1);
   }
   UnmarkCopierEntry(ticket);
}

void ProcessTradeEvents() {
   static bool isReconciling = false;
   if(isReconciling) {
      return;
   }
   
   isReconciling = true;
   
   int activeTickets[];
   ArrayResize(activeTickets, 0);
   int totalOrders = OrdersTotal();

   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int ticket = OrderTicket();
      string comment = OrderComment();

      int size = ArraySize(activeTickets);
      ArrayResize(activeTickets, size + 1);
      activeTickets[size] = ticket;

      int magic = OrderMagicNumber();

      if(StringLen(comment) > 0 && StringToInteger(comment) == magic && magic > 0) continue;

      double currentPrice = OrderOpenPrice();
      double currentSL = OrderStopLoss();
      double currentTP = OrderTakeProfit();
      double currentLots = OrderLots();

      int masterTicketFromComment = ExtractParentTicketFromComment(comment);
      int masterTicket = ResolveLifecycleTicketForOrder(ticket, comment);

      int stateIdx = FindOrderStateIndex(ticket);
      bool isNew = !ArrayContains(g_reportedOpenTickets, ticket);

      if(isNew) {
         bool hasFromComment = (StringFind(comment, "from #") >= 0 || StringFind(comment, "FROM #") >= 0);

         if(hasFromComment && masterTicketFromComment > 0) {
            int ultimateMasterTicket = GetUltimateMasterTicket(masterTicketFromComment);

            int parentStateIdx = FindOrderStateIndex(masterTicketFromComment);
            double closedVolume = 0;
            double closePrice = currentPrice;
            datetime closeTime = TimeCurrent();
            datetime openTime = OrderOpenTime();

            if(parentStateIdx >= 0) {
               OrderState parentState = g_orderStates[parentStateIdx];
               double parentVolume = parentState.lots;
               closedVolume = parentVolume - currentLots;

               int total = OrdersHistoryTotal();
               for(int j = total - 1; j >= 0 && j > total - 200; j--) {
                  if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
                  if(OrderTicket() == masterTicketFromComment) {
                     string historyComment = OrderComment();
                     if(StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0) {
                        closePrice = OrderClosePrice();
                        closeTime = OrderCloseTime();
                        break;
                     }
                  }
               }
            } else {
               int total = OrdersHistoryTotal();
               for(int j = total - 1; j >= 0 && j > total - 200; j--) {
                  if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
                  int historyTicket = OrderTicket();
                  string historyComment = OrderComment();

                  if(historyTicket == masterTicketFromComment) {
                     if(StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0) {
                        double historyLots = OrderLots();
                        closePrice = OrderClosePrice();
                        closeTime = OrderCloseTime();
                        closedVolume = historyLots - currentLots;
                        break;
                     }
                  }
               }
            }

            if(closedVolume <= 0) {
               ArrayPush(g_reportedOpenTickets, ticket);
               UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, ultimateMasterTicket, OrderType());
               continue;
            }

            if(!ArrayContains(g_reportedOpenTickets, ticket)) {

               double profit = 0;
               double swap = 0;
               double commission = 0;
               double openPrice = OrderOpenPrice();

               int total = OrdersHistoryTotal();
               for(int j = total - 1; j >= 0 && j > total - 200; j--) {
                  if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
                  if(OrderTicket() == masterTicketFromComment) {
                     string historyComment = OrderComment();
                     if(StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0) {
                        double historyVolume = OrderLots();
                        if(historyVolume > 0) {
                           double volumeRatio = closedVolume / historyVolume;
                           profit = OrderProfit() * volumeRatio;
                           swap = OrderSwap() * volumeRatio;
                           commission = OrderCommission() * volumeRatio;
                        }
                        openPrice = OrderOpenPrice();
                        break;
                     }
                  }
               }

               string eventJson = BuildModifiedEventJson(ultimateMasterTicket, OrderType(), currentPrice, currentSL, currentTP, currentLots);
               QueueEvent(eventJson, 0);

               ArrayPush(g_reportedOpenTickets, ticket);

               RegisterTicketMap(ticket, ultimateMasterTicket);
            } else {
            }

            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, ultimateMasterTicket, OrderType());
         } else {
            long placedAgeSec;
            if(OrderType() == OP_BUY || OrderType() == OP_SELL)
               placedAgeSec = (long)(TimeCurrent() - OrderOpenTime());
            else
               placedAgeSec = 0;
            if(placedAgeSec < 0) placedAgeSec = 0;
            string eventJson = BuildOrderEventJson("placed", masterTicket, OrderSymbol(), OrderType(), currentLots, currentPrice, currentSL, currentTP, comment, OrderMagicNumber(), placedAgeSec);
            QueueEvent(eventJson, 0);

            ArrayPush(g_reportedOpenTickets, ticket);
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, masterTicket, OrderType());
         }
      } else if(stateIdx >= 0) {
         OrderState prevState = g_orderStates[stateIdx];
         bool hasChanges = false;
         bool isPartialClose = false;

         bool wasPendingNowMarket = (prevState.orderType > OP_SELL && (OrderType() == OP_BUY || OrderType() == OP_SELL));
         if(wasPendingNowMarket) {
         } else {
            if(OrderType() > OP_SELL) {
               if(MathAbs(prevState.price - currentPrice) > 0.00001) {
                  hasChanges = true;
               }
            }

            if(MathAbs(prevState.sl - currentSL) > 0.00001) {
               hasChanges = true;
            }
            if(MathAbs(prevState.tp - currentTP) > 0.00001) {
               hasChanges = true;
            }

            if(MathAbs(prevState.lots - currentLots) > 0.00001) {
               hasChanges = true;
               if(currentLots < prevState.lots && (OrderType() == OP_BUY || OrderType() == OP_SELL)) {
                  isPartialClose = true;
               }
            }
         }

         if(hasChanges) {
            int reportTicket = prevState.originalTicket > 0 ? prevState.originalTicket : masterTicket;
            if(reportTicket == 0) reportTicket = masterTicket;
            int parentFromComment = ExtractParentTicketFromComment(comment);
            if(parentFromComment > 0) {
               int ultimate = GetUltimateMasterTicket(parentFromComment);
               reportTicket = (ultimate > 0) ? ultimate : parentFromComment;
            }

            datetime openTime = OrderOpenTime();

            if(isPartialClose) {
               int parentTicketFromComment = ExtractParentTicketFromComment(comment);

               int initialMasterTicket = reportTicket;
               if(parentTicketFromComment > 0) {
                  initialMasterTicket = parentTicketFromComment;
               } else if(prevState.originalTicket > 0) {
                  initialMasterTicket = prevState.originalTicket;
               } else {
                  initialMasterTicket = prevState.ticket;
               }

               int ultimateMasterTicket = GetUltimateMasterTicket(initialMasterTicket);

               double closedVolume = prevState.lots - currentLots;
               double originalVolume = prevState.lots;

               double profit = 0;
               double swap = 0;
               double commission = 0;
               double openPrice = prevState.price;
               datetime closeTime = TimeCurrent();

               int total = OrdersHistoryTotal();
               for(int j = total - 1; j >= 0 && j > total - 200; j--) {
                  if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
                  if(OrderTicket() == ultimateMasterTicket || OrderTicket() == prevState.ticket) {
                     string historyComment = OrderComment();
                     if(StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0) {
                        double historyVolume = OrderLots();
                        if(historyVolume > 0) {
                           double volumeRatio = closedVolume / historyVolume;
                           profit = OrderProfit() * volumeRatio;
                           swap = OrderSwap() * volumeRatio;
                           commission = OrderCommission() * volumeRatio;
                        }
                        openPrice = OrderOpenPrice();
                        closeTime = OrderCloseTime();
                        break;
                     }
                  }
               }

               string eventJson = BuildModifiedEventJson(ultimateMasterTicket, OrderType(), currentPrice, currentSL, currentTP, currentLots);
               QueueEvent(eventJson, 0);

               ArrayPush(g_reportedOpenTickets, ticket);

               RegisterTicketMap(ticket, ultimateMasterTicket);

               UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, ultimateMasterTicket, OrderType());
      } else {
               string eventJson = BuildModifiedEventJson(reportTicket, OrderType(), currentPrice, currentSL, currentTP, currentLots);
               QueueEvent(eventJson, 0);
               UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, reportTicket, OrderType());
            }
         } else {
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, masterTicket, OrderType());
         }
      } else {
         UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, masterTicket, OrderType());
      }
   }

   for(int i = ArraySize(g_orderStates) - 1; i >= 0; i--) {
      int ticket = g_orderStates[i].ticket;

      bool stillActive = false;
      for(int j = 0; j < ArraySize(activeTickets); j++) {
         if(activeTickets[j] == ticket) {
            stillActive = true;
            break;
         }
      }

      if(!stillActive) {
         int stateIdxClean = FindOrderStateIndex(ticket);
         if(stateIdxClean >= 0) {
            int origTicketClean = g_orderStates[stateIdxClean].originalTicket;
            if(origTicketClean > 0 && origTicketClean != ticket) {
               RemoveOrderState(ticket);
               continue;
            }
         }

         int stateIdx = FindOrderStateIndex(ticket);
         int masterTicket = ticket;
         if(stateIdx >= 0 && g_orderStates[stateIdx].originalTicket > 0) {
            masterTicket = g_orderStates[stateIdx].originalTicket;
         } else {
            int mappedMaster = GetOriginalTicket(ticket);
            if(mappedMaster != ticket) {
               masterTicket = mappedMaster;
            }
         }

         bool isPartialCloseReplacement = false;
         string searchFrom = "from #" + IntegerToString(ticket);
         for(int k = 0; k < ArraySize(activeTickets); k++) {
            if(OrderSelect(activeTickets[k], SELECT_BY_TICKET)) {
               string activeComment = OrderComment();
               if(StringFind(activeComment, searchFrom) >= 0) {
                  isPartialCloseReplacement = true;
                  break;
               }
            }
         }

         if(isPartialCloseReplacement) {
            RemoveOrderState(ticket);
            continue;
         }

         bool alreadyReported = ArrayContains(g_reportedClosedTickets, masterTicket);

         if(!alreadyReported) {
            int total = OrdersHistoryTotal();
            bool found = false;
            for(int j = total - 1; j >= 0 && j > total - 200; j--) {
               if(!OrderSelect(j, SELECT_BY_POS, MODE_HISTORY)) continue;
               int historyTicket = OrderTicket();
               if(historyTicket == ticket || historyTicket == masterTicket) {
                  string historyComment = OrderComment();

                  bool isPartialCloseInHistory = (StringFind(historyComment, "to #") >= 0 || StringFind(historyComment, "TO #") >= 0);

                  if(isPartialCloseInHistory && historyTicket == ticket) {
                     found = true;
                     break;
                  }
                  if(isPartialCloseInHistory && historyTicket == masterTicket) {
                     continue;
                  }

                  string eventType = (OrderType() == OP_BUY || OrderType() == OP_SELL) ? "closed" : "deleted";
                  string eventJson = BuildHistoryEventPayloadWithTicket(eventType, masterTicket);
                  QueueEvent(eventJson, 0);
                  found = true;
                  break;
               }
            }
            if(!found) {

               string eventJson = "{";
               eventJson += "\"event\":\"closed\",";
               eventJson += StringFormat("\"ticket\":%d", masterTicket);
               eventJson += "}";
               QueueEvent(eventJson, 0);
            }
            ArrayPush(g_reportedClosedTickets, masterTicket);
         }
         RemoveOrderState(ticket);
      }
   }
   
   isReconciling = false;
}

string BuildModifiedEventJson(const int ticket, const int orderType, const double price, const double sl, const double tp, const double volume = 0) {

   string json = "{";
   json += "\"event\":\"modified\",";
   json += StringFormat("\"ticket\":%d,", ticket);
   json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
   json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
   json += StringFormat("\"price\":%.5f,", price);
   json += StringFormat("\"volume\":%.2f", volume);
   json += "}";
   return json;
}

string BuildOrderEventJson(const string eventType, const int ticket, const string symbol, const int orderType,
                          const double volume, const double price, const double sl, const double tp,
                          const string comment, const int magic = 0, const long ageSeconds = 0) {
   string json = "{";
   json += "\"event\":" + BridgeJsonQuote(eventType) + ",";
   json += StringFormat("\"ticket\":%d,", ticket);
   json += "\"symbol\":" + BridgeJsonQuote(symbol) + ",";
   json += "\"type\":" + BridgeJsonQuote((orderType <= OP_SELL) ? "market" : PendingTypeString(orderType)) + ",";
   json += "\"side\":" + BridgeJsonQuote((orderType == OP_SELL || orderType == OP_SELLLIMIT || orderType == OP_SELLSTOP) ? "sell" : "buy") + ",";
   json += StringFormat("\"volume\":%.2f,", volume);
   json += StringFormat("\"price\":%.5f,", price);
   json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
   json += (tp == 0) ? "\"tp\":null" : StringFormat("\"tp\":%.5f", tp);

   if(StringLen(comment) > 0) {
      json += ",\"comment\":" + BridgeJsonQuote(comment);
   }
   if(eventType == "placed" || eventType == "modified") {
      long age = (ageSeconds >= 0) ? ageSeconds : 0;
      json += StringFormat(",\"age_seconds\":%d", (int)age);
   }
   json += "}";
   return json;
}

string BuildHistoryEventPayloadWithTicket(const string eventType, int ticketToReport) {

   string json = "{";
   json += "\"event\":\"closed\",";
   json += StringFormat("\"ticket\":%d", ticketToReport);
   json += "}";
   return json;
}

string EscapeJsonString(const string s) {
   string out = "";
   int len = StringLen(s);
   for(int i = 0; i < len; i++) {
      int ch = (int)StringGetCharacter(s, i);
      if(ch == (int)'"') out += "\\\"";
      else if(ch == (int)'\\') out += "\\\\";
      else out += CharToString((uchar)ch);
   }
   return out;
}

string BuildAccountInfoJson() {
   string account = "{";
   account += StringFormat("\"login\":%d,", AccountNumber());
   account += "\"server\":\"" + EscapeJsonString(g_effectiveServer) + "\",";
   account += "\"platform\":\"metatrader4\",";
   account += "\"name\":\"" + EscapeJsonString(AccountName()) + "\",";
   account += "\"currency\":\"" + EscapeJsonString(AccountCurrency()) + "\",";
   account += StringFormat("\"balance\":%.2f,", AccountBalance());
   account += StringFormat("\"equity\":%.2f,", AccountEquity());
   account += StringFormat("\"leverage\":%d}", AccountLeverage());
   return account;
}

string BuildSnapshotEventJson() {
   double balance = AccountBalance();
   double equity = AccountEquity();
   g_snapSeq++;
   string json = "{";
   json += "\"event\":\"snapshot\",";
   json += "\"session\":" + IntegerToString(g_snapSession) + ",\"seq\":" + IntegerToString(g_snapSeq) + ",";
   json += "\"platform\":\"metatrader4\",";
   json += "\"account\":{";
   json += "\"account_id\":\"" + IntegerToString(AccountNumber()) + "\",";
   json += "\"server\":\"" + EscapeJsonString(g_effectiveServer) + "\",";
   json += "\"currency\":\"" + EscapeJsonString(AccountCurrency()) + "\",";
   json += StringFormat("\"balance\":%.2f,", balance);
   json += StringFormat("\"equity\":%.2f,", equity);
   json += StringFormat("\"unrealized_pnl\":%.2f,", equity - balance);
   json += StringFormat("\"leverage\":%d},", AccountLeverage());
   json += "\"open_positions\":[";
   int openCount = 0;
   int pendingCount = 0;
   bool posFirst = true;
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int orderType = OrderType();
      if(orderType != OP_BUY && orderType != OP_SELL) continue;
      openCount++;
      int nativeTicket = OrderTicket();
      string posComment = OrderComment();
      int ticket = ResolveLifecycleTicketForOrder(nativeTicket, posComment);
      double vol = OrderLots();
      double openPrice = OrderOpenPrice();
      double sl = OrderStopLoss();
      double tp = OrderTakeProfit();
      datetime openTime = OrderOpenTime();
      long ageSec = (long)(TimeCurrent() - openTime);
      if(ageSec < 0) ageSec = 0;
      if(!posFirst) json += ",";
      posFirst = false;
      json += "{";
      json += "\"ticket\":" + IntegerToString(ticket) + ",";
      json += "\"symbol\":\"" + OrderSymbol() + "\",";
      json += "\"type\":\"market\",";
      json += "\"side\":\"" + (orderType == OP_SELL ? "sell" : "buy") + "\",";
      json += StringFormat("\"volume\":%.2f,", vol);
      json += StringFormat("\"open_price\":%.5f,", openPrice);
      json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
      json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
      json += "\"age_seconds\":" + IntegerToString((int)ageSec) + ",";
      json += StringFormat("\"profit\":%.2f", OrderProfit() + OrderSwap() + OrderCommission());
      json += "}";
   }
   json += "],";
   json += "\"pending_orders\":[";
   bool ordFirst = true;
   for(int i = 0; i < OrdersTotal(); i++) {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int orderType = OrderType();
      if(orderType != OP_BUYLIMIT && orderType != OP_SELLLIMIT && orderType != OP_BUYSTOP && orderType != OP_SELLSTOP) continue;
      pendingCount++;
      int nativeTicket = OrderTicket();
      string ordComment = OrderComment();
      int ticket = ResolveLifecycleTicketForOrder(nativeTicket, ordComment);
      string typeStr = (orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT) ? "limit" : "stop";
      double vol = OrderLots();
      double price = OrderOpenPrice();
      double sl = OrderStopLoss();
      double tp = OrderTakeProfit();
      datetime openTimeOrd = OrderOpenTime();
      long ageSecOrd = (long)(TimeCurrent() - openTimeOrd);
      if(ageSecOrd < 0) ageSecOrd = 0;
      if(!ordFirst) json += ",";
      ordFirst = false;
      json += "{";
      json += "\"ticket\":" + IntegerToString(ticket) + ",";
      json += "\"symbol\":\"" + OrderSymbol() + "\",";
      json += "\"type\":\"" + typeStr + "\",";
      json += "\"side\":\"" + (orderType == OP_SELLLIMIT || orderType == OP_SELLSTOP ? "sell" : "buy") + "\",";
      json += StringFormat("\"volume\":%.2f,", vol);
      json += StringFormat("\"price\":%.5f,", price);
      json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
      json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
      json += "\"age_seconds\":" + IntegerToString((int)ageSecOrd);
      json += "}";
   }
   json += "],";
   json += "\"open_positions_count\":" + IntegerToString(openCount) + ",";
   json += "\"pending_orders_count\":" + IntegerToString(pendingCount);
   json += "}";
   return json;
}

datetime ParseIso(const string iso) {
   string normalized = iso;
   StringReplace(normalized, "T", " ");
   StringReplace(normalized, "Z", "");
   StringReplace(normalized, "-", ".");
   datetime parsed = StringToTime(normalized);
   if(parsed == 0) parsed = TimeCurrent();
   return parsed;
}

string ToIso(const datetime value) {
   MqlDateTime tm;
   TimeToStruct(value, tm);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
                       tm.year, tm.mon, tm.day, tm.hour, tm.min, tm.sec);
}

long ToUnixUtc(const datetime serverTime) {
   datetime serverNow = TimeCurrent();
   datetime gmtNow = TimeGMT();
   int serverOffsetSeconds = (int)(serverNow - gmtNow);
   return (long)(serverTime - serverOffsetSeconds);
}

long MakeUtcTimestamp(int year, int month, int day, int hour, int min, int sec) {
   if(month < 1 || month > 12 || day < 1 || day > 31) return 0;
   int monthDays[] = {0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};
   int doy = monthDays[month - 1] + day - 1;
   if(month > 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) doy++;
   int tm_year = year - 1900;
   long secs = (long)sec + (long)min * (long)60 + (long)hour * (long)3600;
   secs += (long)doy * (long)86400;
   secs += (long)(tm_year - 70) * (long)31536000;
   secs += (long)((tm_year - 69) / 4) * (long)86400;
   secs -= (long)((tm_year - 1) / 100) * (long)86400;
   secs += (long)((tm_year + 299) / 400) * (long)86400;
   return (long)secs;
}

#define UNIX_EPOCH_2000_SEC 946684800
long DealTimeToUnixUtc(const datetime dealTime) {
   if(dealTime > 0 && dealTime < 1000000000)
      return (long)dealTime + UNIX_EPOCH_2000_SEC;
   return ToUnixUtc(dealTime);
}

long GetCurrentUnixUtc() {
   datetime gmtNow = TimeGMT();
   if(gmtNow <= 0) gmtNow = TimeCurrent();
   MqlDateTime tm;
   TimeToStruct(gmtNow, tm);
   return MakeUtcTimestamp(tm.year, tm.mon, tm.day, tm.hour, tm.min, tm.sec);
}

bool ArrayContains(const int &arr[], const int value) {
   int total = ArraySize(arr);
   for(int i = 0; i < total; i++) {
      if(arr[i] == value) return true;
   }
   return false;
}

void ArrayPush(int &arr[], const int value) {
   int size = ArraySize(arr);
   ArrayResize(arr, size + 1);
   arr[size] = value;
}

string PendingTypeString(const int type) {
   if(type == OP_BUYLIMIT)  return "limit";
   if(type == OP_SELLLIMIT) return "limit";
   if(type == OP_BUYSTOP)   return "stop";
   if(type == OP_SELLSTOP)  return "stop";
   return "pending";
}

void QueueEvent(string eventJson, int priority = 0) {
   if(StringLen(eventJson) == 0) {
      return;
   }
   
   int size = ArraySize(g_eventQueue);
   int newSize = size + 1;
   ArrayResize(g_eventQueue, newSize);
   
   if(ArraySize(g_eventQueue) == newSize) {
      g_eventQueue[size].eventJson = eventJson;
      g_eventQueue[size].priority = priority;
   }
}

void ProcessEventQueue() {
   if(g_isProcessingEvent) {
      return;
   }
   
   int queueSize = ArraySize(g_eventQueue);
   if(queueSize == 0) {
      return;
   }

   g_isProcessingEvent = true;

   int processedCount = 0;
   while(ArraySize(g_eventQueue) > 0) {
      string eventJson = g_eventQueue[0].eventJson;

      if(StringLen(eventJson) > 0) {
         int result = PushLocalEvent(eventJson);
         processedCount++;
      }

      int currentSize = ArraySize(g_eventQueue);
      int newSize = currentSize - 1;
      if(newSize > 0) {
         EventQueueItem tempQueue[];
         ArrayResize(tempQueue, newSize);
         for(int i = 0; i < newSize; i++) {
            tempQueue[i] = g_eventQueue[i + 1];
         }
         ArrayResize(g_eventQueue, newSize);
         for(int i = 0; i < newSize; i++) {
            g_eventQueue[i] = tempQueue[i];
         }
      } else {
         ArrayResize(g_eventQueue, 0);
      }
   }

   g_isProcessingEvent = false;
}

void QueueCommand(string commandJson, long commandId) {
   if(StringLen(commandJson) == 0) return;
   
   int size = ArraySize(g_commandQueue);
   int newSize = size + 1;
   ArrayResize(g_commandQueue, newSize);
   
   if(ArraySize(g_commandQueue) == newSize) {
      g_commandQueue[size].commandJson = commandJson;
      g_commandQueue[size].commandId = commandId;
   }
}

void ProcessCommandQueue() {
   if(g_isProcessingCommand) return;
   
   int queueSize = ArraySize(g_commandQueue);
   if(queueSize == 0) return;

   g_isProcessingCommand = true;

   while(ArraySize(g_commandQueue) > 0) {
      string commandJson = g_commandQueue[0].commandJson;

      if(StringLen(commandJson) > 0) {
         HandleCommand(commandJson);
      }

      int currentSize = ArraySize(g_commandQueue);
      int newSize = currentSize - 1;
      if(newSize > 0) {
         CommandQueueItem tempQueue[];
         ArrayResize(tempQueue, newSize);
         for(int i = 0; i < newSize; i++) {
            tempQueue[i] = g_commandQueue[i + 1];
         }
         ArrayResize(g_commandQueue, newSize);
         for(int i = 0; i < newSize; i++) {
            g_commandQueue[i] = tempQueue[i];
         }
      } else {
         ArrayResize(g_commandQueue, 0);
      }
   }

   g_isProcessingCommand = false;
}
