#property copyright "IPTRADE COPIER LLC"
#property link      "https://jometa9.github.io/IPTRADE"
#property version   "1.0"
#property description "IPTRADE MetaTrader 5 expert advisor for trade copier IPTRADE"
#property strict
#property icon      "\\Images\\logo.ico"

#include <Bridge/BridgeJson.mqh>
#include <Trade\Trade.mqh>

#import "copybridge.dll"
int   InitRestServer(string external_url, int min_port, int max_port);
void  StopRestServer();
int   PollNextCommand(uchar &buffer[], int buffer_len);
int   AckCommand(long command_id, int result_code, string message, string data_json);
int   PushLocalEvent(string json_event);
int   GetAssignedPort();
int   SendReadyNotification(string account_json, int local_port);
void  SetTerminalConnected(int is_connected);
#import

int SendAckInternal(const long command_id, const int result_code, const string message, const string data_json, const int sourceLine) {
   if(result_code < 0) {
      string safeMessage = "Error on line " + IntegerToString(sourceLine);
      if(StringLen(message) > 0)
         safeMessage = safeMessage + " | " + message;
      string safeData = "{\"success\":false,\"error\":\"" + safeMessage + "\"}";
      return AckCommand(command_id, result_code, safeMessage, safeData);
   }
   return AckCommand(command_id, result_code, message, data_json);
}

#define AckCommand(command_id, result_code, message, data_json) SendAckInternal(command_id, result_code, message, data_json, __LINE__)

#define MARKET_ORDER_MAX_AGE_SEC 5
// Grace window during which a just-issued copy-open blocks a duplicate open of the
// same master ticket, even before the broker has surfaced the slave position/order.
#define COPY_INFLIGHT_GRACE_SEC 30

string InpExternalServerUrl   = "";
int    InpPortMin             = 0;
int    InpPortMax             = 0;
int    InpEventCheckIntervalMs = 250;

CTrade  g_trade;
int     g_bridgePort       = -1;
uchar   g_commandBuffer[];
int     g_bufferSize       = 1048576;
uint    g_lastPingTickMs   = 0;
int     g_timerSeconds     = 1;

long    g_lastAccountLogin = 0;
string  g_lastAccountServer = "";
string  g_effectiveServer = "";

// Snapshot ordering: as MASTER we stamp every snapshot with a session (fixed per EA run)
// and a monotonic seq (+1 per snapshot). As SLAVE we keep the last (session,seq) applied
// and ignore any snapshot that isn't newer, so stale/out-of-order/replayed snapshots can
// never drive a close. See BuildSnapshotEventJson and HandleReconcileSnapshot.
long    g_snapSession = 0;   // master: this run's id; set in OnInit
long    g_snapSeq = 0;       // master: monotonic snapshot counter
long    g_lastSnapSession = 0;  // slave: session of the last snapshot applied
long    g_lastSnapSeq = 0;      // slave: seq of the last snapshot applied

ulong   g_reportedPositions[];
ulong   g_reportedDeals[];
ulong   g_reportedOrders[];
ulong   g_partialClosedTickets[];

ulong   g_lastSnapshotOpenTickets[];     // raw POSITION_TICKETs in the last EMITTED snapshot

// In-flight copy-open guard: master tickets for which we just issued an open but the
// broker may not have surfaced the slave position/order yet. A second trigger for the
// same ticket (the 5s snapshot or the on-connect snapshot replay) must NOT open a
// duplicate while the first open is still settling. Entries expire by time (grace).
ulong    g_inflightOpenTickets[];
datetime g_inflightOpenTimes[];

struct OrderState {
   ulong ticket;
   ulong originalTicket;
   double price;
   double sl;
   double tp;
   double lots;
};
OrderState g_orderStates[];

struct TicketMap {
   ulong currentTicket;
   ulong originalTicket;
};
TicketMap g_ticketMaps[];

struct PositionLifecycleState {
   ulong positionTicket;
   ulong lifecycleTicket;
};
PositionLifecycleState g_positionLifecycleStates[];

struct CopierEntry {
   ulong slaveTicket;
   ulong masterTicket;
};
CopierEntry g_copierEntries[];
bool g_inSlaveCommand = false;

string ToLowerString(const string str) {
   string result = str;
   StringToLower(result);
   return result;
}

string ToUpperString(const string str) {
   string result = str;
   StringToUpper(result);
   return result;
}

string TrimString(const string str) {
   string result = str;
   StringTrimLeft(result);
   StringTrimRight(result);
   return result;
}

bool IsTerminalConnected() {
   return (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
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

string ReadServerFromIniFile(const string iniPath) {
   int handle = FileOpen(iniPath, FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(handle == INVALID_HANDLE) return "";

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
      if((key == "server" || key == "lastscanserver" || key == "lastserver") && StringLen(value) > 0) {
         resolvedServer = value;
         break;
      }
   }

   FileClose(handle);
   return resolvedServer;
}

string GetEffectiveServerName() {
   string fallbackServer = AccountInfoString(ACCOUNT_SERVER);
   string commonIniDataPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\config\\common.ini";
   string resolvedServer = ReadServerFromIniFile(commonIniDataPath);
   if(StringLen(resolvedServer) > 0) return resolvedServer;

   string commonIniSharedPath = TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\config\\common.ini";
   resolvedServer = ReadServerFromIniFile(commonIniSharedPath);
   if(StringLen(resolvedServer) > 0) return resolvedServer;

   string terminalIniPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\config\\terminal.ini";
   resolvedServer = ReadServerFromIniFile(terminalIniPath);
   if(StringLen(resolvedServer) > 0) return resolvedServer;

   return fallbackServer;
}

double GetPositionCommission(const ulong positionTicket) {
   double commission = 0.0;
   if(!HistorySelect(0, TimeCurrent())) return 0.0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong dealPositionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPositionId == positionTicket) {
         commission += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      }
   }
   return commission;
}

void AddAllSymbolsToMarketWatch() {
   int totalSymbols = SymbolsTotal(false);
   int addedCount = 0;
   int errorCount = 0;

   for(int i = 0; i < totalSymbols; i++) {
      string symbolName = SymbolName(i, false);

      if(StringLen(symbolName) == 0) continue;

      bool alreadyVisible = (bool)SymbolInfoInteger(symbolName, SYMBOL_SELECT);

      if(!alreadyVisible) {

         if(SymbolSelect(symbolName, true)) {
            addedCount++;
         } else {
            errorCount++;
         }
      }

      if(SymbolInfoInteger(symbolName, SYMBOL_SELECT)) {

         MqlTick tick;
         SymbolInfoTick(symbolName, tick);
      }
   }
}

void ReconcileInitialState() {
   ArrayResize(g_reportedPositions, 0);
   ArrayResize(g_reportedDeals, 0);
   ArrayResize(g_reportedOrders, 0);
   ArrayResize(g_partialClosedTickets, 0);
   ArrayResize(g_orderStates, 0);
   ArrayResize(g_ticketMaps, 0);
   ArrayResize(g_positionLifecycleStates, 0);
   ArrayResize(g_lastSnapshotOpenTickets, 0);   // fresh snapshot baseline for this account
   ArrayResize(g_inflightOpenTickets, 0);
   ArrayResize(g_inflightOpenTimes, 0);

   int i;
   for(i = PositionsTotal() - 1; i >= 0; i--) {
      string symbol = PositionGetSymbol(i);
      if(symbol == "") continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      long magic = PositionGetInteger(POSITION_MAGIC);
      string comment = PositionGetString(POSITION_COMMENT);

      if(StringLen(comment) > 0 && StringToInteger(comment) == (int)magic && magic > 0) continue;

      ArrayPushU(g_reportedPositions, ticket);
      ulong lifecycleTicket = ResolveLifecycleTicketForPosition(ticket, comment);
      UpdateOrderState(ticket, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_VOLUME), lifecycleTicket);
   }

   for(i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      long magic = OrderGetInteger(ORDER_MAGIC);
      string comment = OrderGetString(ORDER_COMMENT);

      if(StringLen(comment) > 0 && StringToInteger(comment) == (int)magic && magic > 0) continue;

      ArrayPushU(g_reportedOrders, ticket);
      UpdateOrderState(ticket, OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL), OrderGetDouble(ORDER_TP), OrderGetDouble(ORDER_VOLUME_CURRENT));
   }
}

int OnInit() {
   ArrayResize(g_commandBuffer, g_bufferSize);

   g_snapSession = (long)TimeGMT();   // unique-per-run id so a master restart is detected
   g_snapSeq = 0;
   g_lastSnapSession = 0;             // slave: fresh sync baseline on (re)load / account change
   g_lastSnapSeq = 0;

   AddAllSymbolsToMarketWatch();

   g_bridgePort = InitRestServer(InpExternalServerUrl, InpPortMin, InpPortMax);

   if(g_bridgePort <= 0) {
      return INIT_FAILED;
   }
   
   g_lastAccountLogin  = AccountInfoInteger(ACCOUNT_LOGIN);
   LoadCopierEntries();
   PurgeStaleCopierEntries();

   ReconcileInitialState();

   g_lastAccountServer = AccountInfoString(ACCOUNT_SERVER);
   g_effectiveServer   = GetEffectiveServerName();

   EventSetMillisecondTimer(InpEventCheckIntervalMs);

   g_timerSeconds = 1;

   string accountInfo = BuildAccountInfoJson();
   int readyResult = SendReadyNotification(accountInfo, g_bridgePort);
   SetTerminalConnected(IsTerminalConnected() ? 1 : 0);

   g_lastPingTickMs = GetTickCount();

   int clearedCount = 0;
   while(true) {
      int len = PollNextCommand(g_commandBuffer, g_bufferSize);
      if(len <= 0) break;
      clearedCount++;
      string json = CharArrayToString(g_commandBuffer, 0, len);
      long oldCmdId = BridgeJsonGetLong(json, "command_id", 0);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   StopRestServer();
}

void ReinitializeForAccountChange(long newLogin, const string newServer) {
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
      int len = PollNextCommand(g_commandBuffer, g_bufferSize);
      if(len <= 0) break;
   }

   g_lastPingTickMs = GetTickCount();
}

void CollectOpenPositionTickets(ulong &out[]) {
   ArrayResize(out, 0);
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetSymbol(i) == "") continue;
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringLen(comment) > 0 && StringToInteger(comment) == (int)magic && magic > 0) continue;
      ArrayPushU(out, PositionGetInteger(POSITION_TICKET));
   }
}

bool SnapshotReflectsRealData() {
   if(!IsTerminalConnected()) return false;
   int n = ArraySize(g_lastSnapshotOpenTickets);
   for(int i = 0; i < n; i++) {
      ulong t = g_lastSnapshotOpenTickets[i];
      if(t == 0) continue;
      if(PositionSelectByTicket(t)) continue;          // still open -> real
      if(ArrayContainsU(g_reportedDeals, t)) continue;  // closed, confirmed by event layer
      return false;                                     // vanished without proof -> not real yet
   }
   return true;
}

void OnTimer() {

   SetTerminalConnected(IsTerminalConnected() ? 1 : 0);

   uint nowTick = GetTickCount();
   bool shouldEmitSnapshot = (nowTick - g_lastPingTickMs >= 5000);
   bool accountChanged = false;
   if(shouldEmitSnapshot) {
      g_lastPingTickMs = nowTick;

      long currentLogin  = AccountInfoInteger(ACCOUNT_LOGIN);
      string currentServer = AccountInfoString(ACCOUNT_SERVER);
      accountChanged = (currentLogin != g_lastAccountLogin) || (currentServer != g_lastAccountServer);
      if(accountChanged) {
         ReinitializeForAccountChange(currentLogin, currentServer);
      }
   }

   // Order matters: emit any trade events (placed/modified/closed) BEFORE the
   // periodic snapshot so the snapshot always reflects the post-event state.
   // Otherwise the slave can see a stale snapshot (built before the event)
   // arrive right after the event and reconcile incorrectly, producing
   // close+reopen artifacts.
   ProcessIncomingCommands();
   ProcessTradeEvents();

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

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result) {
}

void ProcessIncomingCommands() {
   static int callCount = 0;
   callCount++;

   int commandsProcessed = 0;
   while(true) {
      int len = PollNextCommand(g_commandBuffer, g_bufferSize);
      if(len <= 0) {
         break;
      }
      commandsProcessed++;
      string json = CharArrayToString(g_commandBuffer, 0, len);

      if(StringLen(json) > 0) {
         HandleCommand(json);
      }
   }
}

void HandleCommand(const string json) {
   if(StringLen(json) == 0) {
      return;
   }

   long commandId = BridgeJsonGetLong(json, "command_id", 0);
   string actionStr = BridgeJsonGetString(json, "action", "");
   string action = ToLowerString(actionStr);
   string payload = BridgeJsonGetObject(json, "payload");

   if(StringLen(actionStr) == 0) {
      AckCommand(commandId, -1, "empty action field", "");
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
      AckCommand(commandId, -1, "unknown action: " + action, "");
   }
   g_inSlaveCommand = false;
}

double NormalizePrice(const string symbol, const double price) {
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) tickSize = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(tickSize <= 0) return price;
   return MathRound(price / tickSize) * tickSize;
}

double ValidateAndNormalizeSL(const string symbol, const double entryPrice, const string side, const double requestedSL) {
   if(requestedSL <= 0) return 0.0;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) point = 0.00001;

   int stopsLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;

   if(side == "buy") {
      if(requestedSL >= entryPrice) return 0.0;
      double distance = entryPrice - requestedSL;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   } else {
      if(requestedSL <= entryPrice) return 0.0;
      double distance = requestedSL - entryPrice;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   }

   return NormalizePrice(symbol, requestedSL);
}

double ValidateAndNormalizeTP(const string symbol, const double entryPrice, const string side, const double requestedTP) {
   if(requestedTP <= 0) return 0.0;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) point = 0.00001;

   int stopsLevel = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance = stopsLevel * point;

   if(side == "buy") {
      if(requestedTP <= entryPrice) return 0.0;
      double distance = requestedTP - entryPrice;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   } else {
      if(requestedTP >= entryPrice) return 0.0;
      double distance = entryPrice - requestedTP;
      if(minDistance > 0 && distance < minDistance) return 0.0;
   }

   return NormalizePrice(symbol, requestedTP);
}

double NormalizeVolumeForSymbolMT5(const string symbol, const double requestedVolume) {
   double minVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(minVolume <= 0.0) minVolume = 0.01;

   double maxVolume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if(maxVolume <= 0.0) maxVolume = minVolume;

   double volumeStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(volumeStep <= 0.0) volumeStep = minVolume;

   double adjusted = MathMax(minVolume, requestedVolume);
   adjusted = MathMin(adjusted, maxVolume);

   double steps = MathFloor(((adjusted - minVolume) / volumeStep) + 1e-8);
   double normalized = minVolume + (steps * volumeStep);

   int lotDecimals = 0;
   double probe = volumeStep;
   while(lotDecimals < 8 && MathAbs(probe - MathRound(probe)) > 1e-9) {
      probe *= 10.0;
      lotDecimals++;
   }

   normalized = NormalizeDouble(normalized, lotDecimals);
   if(normalized < minVolume) normalized = minVolume;
   if(normalized > maxVolume) normalized = maxVolume;
   return normalized;
}

bool IsInflightOpen(const ulong masterTicket) {
   if(masterTicket == 0) return false;
   datetime now = TimeCurrent();
   for(int i = 0; i < ArraySize(g_inflightOpenTickets); i++) {
      if(g_inflightOpenTickets[i] == masterTicket)
         return (now - g_inflightOpenTimes[i] <= COPY_INFLIGHT_GRACE_SEC);
   }
   return false;
}

void MarkInflightOpen(const ulong masterTicket) {
   if(masterTicket == 0) return;
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

void UnmarkInflightOpen(const ulong masterTicket) {
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
   string type   = ToLowerString(BridgeJsonGetString(payload, "type", "market"));
   string side   = ToLowerString(BridgeJsonGetString(payload, "side", "buy"));
   double volume = BridgeJsonGetDouble(payload, "volume", 0);
   double price  = BridgeJsonGetDouble(payload, "price", 0);
   double sl     = BridgeJsonGetDouble(payload, "sl", 0);
   double tp     = BridgeJsonGetDouble(payload, "tp", 0);

   ulong masterTicket = (ulong)BridgeJsonGetLong(payload, "ticket", 0);
   bool hasMasterTicket = (masterTicket > 0);

   
   string masterIdStr = IntegerToString(masterTicket);
   int masterTicketInt = (int)masterTicket;
   if(hasMasterTicket) {
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == "") continue;
         if(PositionGetString(POSITION_COMMENT) == masterIdStr || (int)PositionGetInteger(POSITION_MAGIC) == masterTicketInt) {
            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)masterTicket) + "}");
            return;
         }
      }
      for(int i = 0; i < OrdersTotal(); i++) {
         ulong ot = OrderGetTicket(i);
         if(ot == 0) continue;
         if(!OrderSelect(ot)) continue;
         if(OrderGetString(ORDER_COMMENT) == masterIdStr || (int)OrderGetInteger(ORDER_MAGIC) == masterTicketInt) {
            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)masterTicket) + "}");
            return;
         }
      }
   }

   // Already opening this master ticket and the broker just hasn't shown it yet:
   // ack as success and skip, so a near-simultaneous snapshot can't double the copy.
   if(hasMasterTicket && IsInflightOpen(masterTicket)) {
      AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)masterTicket) + "}");
      return;
   }

   int magic = hasMasterTicket ? (int)masterTicket : 0;

   bool hasVolumeField = (BridgeJsonFindKey(payload, "volume") >= 0);
   if(symbol == "" || !hasVolumeField) {
      AckCommand(commandId, -1, "invalid payload", "{\"success\":false,\"error\":\"invalid payload\"}");
      return;
   }
   if(!SymbolSelect(symbol, true)) {
      AckCommand(commandId, -1, "symbol unavailable", "{\"success\":false,\"error\":\"symbol unavailable\"}");
      return;
   }

   volume = NormalizeVolumeForSymbolMT5(symbol, volume);

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.symbol = symbol;
   req.volume = volume;
   req.magic  = magic;
   req.deviation = 20;

   req.comment = hasMasterTicket ? IntegerToString(masterTicket) : "";

   int filling_mode = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling_mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) {
      req.type_filling = ORDER_FILLING_FOK;
   } else if((filling_mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) {
      req.type_filling = ORDER_FILLING_IOC;
   } else {
      req.type_filling = ORDER_FILLING_RETURN;
   }

   req.type_time = ORDER_TIME_GTC;

   if(type == "market") {
      long eventAgeSeconds = (long)BridgeJsonGetLong(payload, "age_seconds", -1);
      if(eventAgeSeconds < 0) {
         if(commandId > 0) AckCommand(commandId, -1, "age_seconds required for market order", "{\"success\":false,\"error\":\"age_seconds required for market order\"}");
         return;
      }
      if(eventAgeSeconds > MARKET_ORDER_MAX_AGE_SEC) {
         string errMsg = StringFormat("event too old for market order (%d s > %d s)", (int)eventAgeSeconds, MARKET_ORDER_MAX_AGE_SEC);
         if(commandId > 0) AckCommand(commandId, -1, errMsg, "{\"success\":false,\"error\":\"" + errMsg + "\"}");
         return;
      }
      req.action = TRADE_ACTION_DEAL;
      req.type = (side == "sell") ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price = 0.0;
      req.sl = 0.0;
      req.tp = 0.0;
      double currentPrice = SymbolInfoDouble(symbol, (side == "sell") ? SYMBOL_BID : SYMBOL_ASK);
   } else if(type == "limit") {

      req.action = TRADE_ACTION_PENDING;
      req.type = (side == "sell") ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;
      req.price = price;
      req.sl = sl;
      req.tp = tp;
   } else if(type == "stop" || type == "stop_limit") {

      req.action = TRADE_ACTION_PENDING;
      req.type = (side == "sell") ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
      req.price = price;
      req.sl = sl;
      req.tp = tp;
   } else {
      AckCommand(commandId, -1, "unsupported type", "{\"success\":false,\"error\":\"unsupported type\"}");
      return;
   }

   if(type != "market" && req.price <= 0) {
      AckCommand(commandId, -1, "price missing", "{\"success\":false,\"error\":\"price missing\"}");
      return;
   }

   if(hasMasterTicket) MarkInflightOpen(masterTicket);   // claim the ticket before the (possibly slow) fill
   bool ok = OrderSend(req, res);
   if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)) {
      if(type == "market") {
         Sleep(200);

         bool positionFound = false;
         ulong posTicket = 0;

         datetime latestTime = 0;
         for(int i = 0; i < PositionsTotal(); i++) {
            if(PositionGetSymbol(i) == symbol) {
               if(PositionGetInteger(POSITION_MAGIC) == magic) {
                  datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
                  if(posTime > latestTime) {
                     posTicket = PositionGetInteger(POSITION_TICKET);
                     positionFound = true;
                     latestTime = posTime;
                  }
               }
            }
         }

         if(positionFound && posTicket > 0) {
            ulong lifecycleTicket = ResolveLifecycleTicketForPosition(posTicket, PositionGetString(POSITION_COMMENT));
            if(lifecycleTicket == 0) lifecycleTicket = posTicket;
            if(!hasMasterTicket) {
               masterTicket = lifecycleTicket;
            }
            RegisterTicketMap(posTicket, masterTicket);
            if(sl > 0 || tp > 0) {
               g_trade.PositionModify(posTicket, sl, tp);
            }
            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)masterTicket) + "}");
         } else {
            ulong fallbackTicket = (res.order > 0) ? res.order : (ulong)res.deal;
            if(fallbackTicket == 0) fallbackTicket = masterTicket;
            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)fallbackTicket) + "}");
         }
      } else {
         ulong lifecycleTicket = res.order;
         if(hasMasterTicket) {
            lifecycleTicket = masterTicket;
         }
         RegisterTicketMap(res.order, lifecycleTicket);
         AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null,\"ticket\":" + IntegerToString((int)lifecycleTicket) + "}");
      }
   } else {
      if(hasMasterTicket) UnmarkInflightOpen(masterTicket);   // open failed -> release so a later snapshot can retry
      string errorMsg = StringFormat("OrderSend failed (retcode=%d)", res.retcode);
      AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
   }
}

void HandleModify(const long commandId, const string payload) {
   ulong masterTicket = (ulong)BridgeJsonGetLong(payload, "ticket", 0);

   if(masterTicket == 0) {
      AckCommand(commandId, -1, "ticket is required", "{\"success\":false,\"error\":\"ticket is required\"}");
      return;
   }

   int debugTotal = PositionsTotal();
   for(int d = 0; d < debugTotal; d++) {
      if(PositionGetSymbol(d) != "") {
      }
   }

   int debugOrders = OrdersTotal();
   for(int d = 0; d < debugOrders; d++) {
      ulong orderTicket = OrderGetTicket(d);
      if(orderTicket > 0) {
      }
   }

   bool found = false;
   ulong currentTicket = 0;

   if(masterTicket > 0) {
      found = SelectPositionByTicket(masterTicket);
      if(found) {
         currentTicket = PositionGetInteger(POSITION_TICKET);
         RegisterTicketMap(currentTicket, masterTicket);
      }
   }

   if(!found && masterTicket > 0) {
      datetime latestTime = 0;
      ulong latestTicket = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++) {
         if(PositionGetSymbol(i) != "") {
            ulong posTicket = PositionGetInteger(POSITION_TICKET);
            int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
            if(posMagic == (int)masterTicket) {
               datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
               if(posTime > latestTime) {
                  latestTime = posTime;
                  latestTicket = posTicket;
               }
            }
         }
      }
      if(latestTicket > 0) {

         if(PositionSelectByTicket(latestTicket)) {
            currentTicket = latestTicket;
            RegisterTicketMap(currentTicket, masterTicket);
            found = true;
         } else {
         }
      }
   }

   if(!found) {
      int total = PositionsTotal();
      for(int i = 0; i < total; i++) {
         if(PositionGetSymbol(i) == "") continue;
         ulong posTicket = PositionGetInteger(POSITION_TICKET);
         string posComment = PositionGetString(POSITION_COMMENT);
         ulong lifecycleTicket = ResolveLifecycleTicketForPosition(posTicket, posComment);
         if(lifecycleTicket == masterTicket) {
            if(PositionSelectByTicket(posTicket)) {
               currentTicket = posTicket;
               RegisterTicketMap(currentTicket, masterTicket);
               found = true;
               break;
            }
         }
      }
   }

   if(found) {
      string symbol = PositionGetString(POSITION_SYMBOL);
      double currentVolume = PositionGetDouble(POSITION_VOLUME);
      double currentVolumeNorm = NormalizeVolumeForSymbolMT5(symbol, currentVolume);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);

      bool volumeChangeRequested = false;
      double newVolume = currentVolume;
      bool volumeRequested = (BridgeJsonFindKey(payload, "volume") >= 0);
      if(volumeRequested) {
         newVolume = BridgeJsonGetDouble(payload, "volume", currentVolume);
         newVolume = NormalizeVolumeForSymbolMT5(symbol, newVolume);
         if(MathAbs(newVolume - currentVolumeNorm) > 0.00001) {
            volumeChangeRequested = true;
         }
      }
      
      bool slRequested = false;
      bool tpRequested = false;
      string positionSide = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      double positionEntryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(BridgeJsonFindKey(payload, "sl") >= 0) {
         slRequested = true;
         bool isSlNull = JsonFieldIsNull(payload, "sl");
         double newSL = isSlNull ? 0.0 : BridgeJsonGetDouble(payload, "sl", 0);
         if(isSlNull || newSL <= 0) {
            sl = 0.0;
         } else {
            double validatedSL = ValidateAndNormalizeSL(symbol, positionEntryPrice, positionSide, newSL);
            if(validatedSL > 0) sl = validatedSL;
         }
      }
      if(BridgeJsonFindKey(payload, "tp") >= 0) {
         tpRequested = true;
         bool isTpNull = JsonFieldIsNull(payload, "tp");
         double newTP = isTpNull ? 0.0 : BridgeJsonGetDouble(payload, "tp", 0);
         if(isTpNull || newTP <= 0) {
            tp = 0.0;
         } else {
            double validatedTP = ValidateAndNormalizeTP(symbol, positionEntryPrice, positionSide, newTP);
            if(validatedTP > 0) tp = validatedTP;
         }
      }
      bool stopsUpdateRequested = (slRequested || tpRequested);

      if(volumeChangeRequested && newVolume < currentVolumeNorm) {
         double closeVolume = currentVolumeNorm - newVolume;
         if(stopsUpdateRequested) {
            bool preModOk = g_trade.PositionModify(currentTicket, sl, tp);
            if(preModOk) {
            } else {
               GetLastError();
            }
         }
         bool ok = g_trade.PositionClosePartial(currentTicket, closeVolume);
         if(ok) {
            Sleep(300);
            string masterIdStr = IntegerToString((int)masterTicket);
            ulong remainingTicket = 0;
            double remainingDiff = 999999.0;
            for(int attempt = 0; attempt < 5; attempt++) {
               for(int i = 0; i < PositionsTotal(); i++) {
                  if(PositionGetSymbol(i) == "") continue;
                  ulong candTicket = PositionGetInteger(POSITION_TICKET);
                  string candComment = PositionGetString(POSITION_COMMENT);
                  int candMagic = (int)PositionGetInteger(POSITION_MAGIC);
                  ulong lifecycle = ResolveLifecycleTicketForPosition(candTicket, candComment);
                  bool belongs = (candTicket == masterTicket) ||
                                 (lifecycle == masterTicket) ||
                                 (candMagic == (int)masterTicket) ||
                                 (candComment == masterIdStr);
                  if(!belongs) continue;
                  double candVol = PositionGetDouble(POSITION_VOLUME);
                  double candDiff = MathAbs(candVol - newVolume);
                  if(remainingTicket == 0 || candDiff < remainingDiff ||
                     (MathAbs(candDiff - remainingDiff) < 0.00001 && candTicket > remainingTicket)) {
                     remainingTicket = candTicket;
                     remainingDiff = candDiff;
                  }
               }
               if(remainingTicket > 0) break;
               Sleep(200);
            }
            if(remainingTicket == 0 && PositionSelectByTicket(currentTicket)) {
               remainingTicket = currentTicket;
            }
            if(remainingTicket > 0 && remainingTicket != currentTicket) {
               RegisterTicketMap(remainingTicket, masterTicket);
            }
            if(remainingTicket > 0 && stopsUpdateRequested) {
               bool modOk = g_trade.PositionModify(remainingTicket, sl, tp);
               if(!modOk) {
                  GetLastError();
               }
            }
            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
         } else {
            int errorCode = GetLastError();
            string errorMsg = StringFormat("Partial close failed (error=%d)", errorCode);
            AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
         }
         return;
      } else if(volumeChangeRequested && newVolume > currentVolumeNorm) {
         AckCommand(commandId, -1, "volume increase not supported for open positions", "{\"success\":false,\"error\":\"volume increase not supported for open positions\"}");
         return;
      }

      bool ok = g_trade.PositionModify(currentTicket, sl, tp);
      if(ok) {
         AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else {
         int errorCode = GetLastError();
         string errorMsg = StringFormat("PositionModify failed (error=%d)", errorCode);
         AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
      }
      return;
   }

   bool orderFound = SelectOrderByTicket(masterTicket);
   if(!orderFound && masterTicket > 0) {
      for(int i = 0; i < OrdersTotal(); i++) {
         ulong ot = OrderGetTicket(i);
         if(ot == 0 || !OrderSelect(ot)) continue;
         ulong mappedOriginal = GetOriginalTicket(ot);
         if(mappedOriginal == masterTicket || ot == masterTicket) {
            orderFound = true;
            break;
         }
      }
   }

   if(orderFound) {

      ulong realOrderTicket = OrderGetInteger(ORDER_TICKET);
      string orderSymbol = OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double currentVolume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double orderSL = OrderGetDouble(ORDER_SL);
      double orderTP = OrderGetDouble(ORDER_TP);
      datetime expiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      int orderMagic = (int)OrderGetInteger(ORDER_MAGIC);
      string orderComment = OrderGetString(ORDER_COMMENT);

      bool volumeChangeRequested = false;
      double newVolume = currentVolume;
      bool volumeRequested = (BridgeJsonFindKey(payload, "volume") >= 0);
      if(volumeRequested) {
         newVolume = BridgeJsonGetDouble(payload, "volume", currentVolume);
         newVolume = NormalizeVolumeForSymbolMT5(orderSymbol, newVolume);
         double currentVolumeNorm = NormalizeVolumeForSymbolMT5(orderSymbol, currentVolume);
         if(MathAbs(newVolume - currentVolumeNorm) > 0.00001) {
            volumeChangeRequested = true;
         }
      }

      bool priceRequested = (BridgeJsonFindKey(payload, "price") >= 0);
      if(priceRequested) {
         orderPrice = BridgeJsonGetDouble(payload, "price", orderPrice);
      }
      string orderSide = "";
      if(orderType == ORDER_TYPE_BUY_LIMIT || orderType == ORDER_TYPE_BUY_STOP || orderType == ORDER_TYPE_BUY_STOP_LIMIT) {
         orderSide = "buy";
      } else {
         orderSide = "sell";
      }
      bool slRequested = (BridgeJsonFindKey(payload, "sl") >= 0);
      if(slRequested) {
         bool isSlNull = JsonFieldIsNull(payload, "sl");
         double newSL = isSlNull ? 0.0 : BridgeJsonGetDouble(payload, "sl", 0);
         if(isSlNull || newSL <= 0) {
            orderSL = 0.0;
         } else {
            double validatedSL = ValidateAndNormalizeSL(orderSymbol, orderPrice, orderSide, newSL);
            if(validatedSL > 0) orderSL = validatedSL;
         }
      }
      bool tpRequested = (BridgeJsonFindKey(payload, "tp") >= 0);
      if(tpRequested) {
         bool isTpNull = JsonFieldIsNull(payload, "tp");
         double newTP = isTpNull ? 0.0 : BridgeJsonGetDouble(payload, "tp", 0);
         if(isTpNull || newTP <= 0) {
            orderTP = 0.0;
         } else {
            double validatedTP = ValidateAndNormalizeTP(orderSymbol, orderPrice, orderSide, newTP);
            if(validatedTP > 0) orderTP = validatedTP;
         }
      }
      bool expireRequested = (BridgeJsonFindKey(payload, "expire") >= 0);
      string expireIso = BridgeJsonGetString(payload, "expire", "");
      if(expireIso != "") {
         expiration = ParseIso(expireIso);
      }

      if(!volumeChangeRequested && !priceRequested && !slRequested && !tpRequested && !expireRequested) {
         AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
         return;
      }

      if(volumeChangeRequested) {

         double validatedSL = ValidateAndNormalizeSL(orderSymbol, orderPrice, orderSide, orderSL);
         double validatedTP = ValidateAndNormalizeTP(orderSymbol, orderPrice, orderSide, orderTP);

         double origPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         double origSL = OrderGetDouble(ORDER_SL);
         double origTP = OrderGetDouble(ORDER_TP);
         double origVolume = OrderGetDouble(ORDER_VOLUME_CURRENT);
         datetime origExpiration = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);

         bool deleteOk = g_trade.OrderDelete(realOrderTicket);
         if(!deleteOk) {
            int errorCode = GetLastError();
            string errorMsg = StringFormat("Failed to delete pending order (error=%d)", errorCode);
            AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
            return;
         }

         MqlTradeRequest req;
         MqlTradeResult res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action = TRADE_ACTION_PENDING;
         req.symbol = orderSymbol;
         req.volume = newVolume;
         req.type = orderType;
         req.price = orderPrice;
         req.sl = validatedSL;
         req.tp = validatedTP;
         req.magic = orderMagic;
         req.comment = orderComment;
         req.expiration = expiration;
         req.type_time = ORDER_TIME_GTC;

         int filling_mode = (int)SymbolInfoInteger(orderSymbol, SYMBOL_FILLING_MODE);
         if((filling_mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) {
            req.type_filling = ORDER_FILLING_FOK;
         } else if((filling_mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) {
            req.type_filling = ORDER_FILLING_IOC;
         } else {
            req.type_filling = ORDER_FILLING_RETURN;
         }

         bool ok = OrderSend(req, res);
         if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)) {
            ulong newTicket = res.order;

            RegisterTicketMap(newTicket, masterTicket);

            RemoveOrderState(realOrderTicket);
            UpdateOrderState(newTicket, orderPrice, validatedSL, validatedTP, newVolume, masterTicket);

            AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
         } else {

            ZeroMemory(req);
            ZeroMemory(res);

            req.action = TRADE_ACTION_PENDING;
            req.symbol = orderSymbol;
            req.volume = origVolume;
            req.type = orderType;
            req.price = origPrice;
            req.sl = origSL;
            req.tp = origTP;
            req.magic = orderMagic;
            req.comment = orderComment;
            req.expiration = origExpiration;
            req.type_time = ORDER_TIME_GTC;

            if((filling_mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) {
               req.type_filling = ORDER_FILLING_FOK;
            } else if((filling_mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) {
               req.type_filling = ORDER_FILLING_IOC;
            } else {
               req.type_filling = ORDER_FILLING_RETURN;
            }

            int originalRetcode = res.retcode;
            bool rollbackOk = OrderSend(req, res);
            if(rollbackOk && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)) {

               ulong rollbackTicket = res.order;
               RegisterTicketMap(rollbackTicket, masterTicket);
               UpdateOrderState(rollbackTicket, origPrice, origSL, origTP, origVolume, masterTicket);
               string errorMsg = StringFormat("Failed to recreate pending order with new volume (retcode=%d), original order restored", originalRetcode);
               AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
            } else {
               string errorMsg = StringFormat("CRITICAL: Failed to recreate pending order (retcode=%d) AND rollback failed (retcode=%d). Order lost!", originalRetcode, res.retcode);
               AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
            }
         }
         return;
      }

      MqlTradeRequest req;
      MqlTradeResult res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action = TRADE_ACTION_MODIFY;
      req.order = realOrderTicket;
      req.symbol = orderSymbol;
      req.price = orderPrice;
      req.sl = orderSL;
      req.tp = orderTP;
      req.expiration = expiration;

      bool ok = OrderSend(req, res);
      if(ok && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_NO_CHANGES)) {
         AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else {
         string errorMsg = StringFormat("Order modify failed (retcode=%d)", res.retcode);
         AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
      }
      return;
   }

   AckCommand(commandId, -1, "ticket not found", "{\"success\":false,\"error\":\"ticket not found\"}");
}

void HandleCancel(const long commandId, const string payload) {
   ulong masterTicket = (ulong)BridgeJsonGetLong(payload, "ticket", 0);
   double closeVolume = BridgeJsonGetDouble(payload, "close_volume", 0);

   if(masterTicket == 0) {
      AckCommand(commandId, -1, "ticket is required", "{\"success\":false,\"error\":\"ticket is required\"}");
      return;
   }

   int debugTotal = PositionsTotal();
   for(int d = 0; d < debugTotal; d++) {
      if(PositionGetSymbol(d) != "") {
      }
   }

   int debugOrders = OrdersTotal();
   for(int d = 0; d < debugOrders; d++) {
      ulong orderTicket = OrderGetTicket(d);
      if(orderTicket > 0) {
      }
   }

   bool found = false;
   ulong currentTicket = 0;

   if(masterTicket > 0) {
      found = SelectPositionByTicket(masterTicket);
      if(found) {
         currentTicket = PositionGetInteger(POSITION_TICKET);
         RegisterTicketMap(currentTicket, masterTicket);
      }
   }

   if(!found && masterTicket > 0) {
      datetime latestTime = 0;
      ulong latestTicket = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++) {
         if(PositionGetSymbol(i) != "") {
            ulong posTicket = PositionGetInteger(POSITION_TICKET);
            int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
            if(posMagic == (int)masterTicket) {
               datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);
               if(posTime > latestTime) {
                  latestTime = posTime;
                  latestTicket = posTicket;
               }
            }
         }
      }
      if(latestTicket > 0) {

         if(PositionSelectByTicket(latestTicket)) {
            currentTicket = latestTicket;
            RegisterTicketMap(currentTicket, masterTicket);
            found = true;
         } else {
         }
      }
   }

   if(!found) {
      int total = PositionsTotal();
      for(int i = 0; i < total; i++) {
         if(PositionGetSymbol(i) == "") continue;
         ulong posTicket = PositionGetInteger(POSITION_TICKET);
         string posComment = PositionGetString(POSITION_COMMENT);
         ulong lifecycleTicket = ResolveLifecycleTicketForPosition(posTicket, posComment);
         if(lifecycleTicket == masterTicket) {
            if(PositionSelectByTicket(posTicket)) {
               currentTicket = posTicket;
               RegisterTicketMap(currentTicket, masterTicket);
               found = true;
               break;
            }
         }
      }
   }

   if(found) {
      double volume = PositionGetDouble(POSITION_VOLUME);
      bool isPartialClose = (closeVolume > 0 && closeVolume < volume);
      if(closeVolume <= 0 || closeVolume > volume) closeVolume = volume;

      ulong originalTicket = masterTicket;

      bool ok = false;
      if(isPartialClose) {
         ok = g_trade.PositionClosePartial(currentTicket, closeVolume);
      } else {
         ok = g_trade.PositionClose(currentTicket);
      }

      if(ok) {
            if(isPartialClose) {
               string originalComment = PositionGetString(POSITION_COMMENT);
               int originalMagic = (int)PositionGetInteger(POSITION_MAGIC);
               string posSymbol = PositionGetString(POSITION_SYMBOL);
               double originalVolume = volume;
               double closedVolume = closeVolume;

               Sleep(300);

               for(int i = 0; i < PositionsTotal(); i++) {
                  string sym = PositionGetSymbol(i);
                  if(sym == posSymbol) {
                     int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
                     if(posMagic == originalMagic) {
                        ulong newTicket = PositionGetInteger(POSITION_TICKET);
                        string newComment = PositionGetString(POSITION_COMMENT);

                        if(StringFind(newComment, "from #") >= 0 && newTicket != currentTicket) {
                           double remainingVolume = PositionGetDouble(POSITION_VOLUME);
                           double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);

                           ulong originalMasterTicket = GetOriginalTicket(originalTicket);
                           if(originalMasterTicket == 0) originalMasterTicket = originalTicket;

                           RegisterTicketMap(newTicket, originalMasterTicket);

                           double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                           double sl = PositionGetDouble(POSITION_SL);
                           double tp = PositionGetDouble(POSITION_TP);
                           datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
                           datetime closeTime = TimeCurrent();
                           ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

                           double profit = 0;
                           double swap = 0;
                           double commission = 0;
                           if(originalVolume > 0) {
                              double volumeRatio = closedVolume / originalVolume;
                              profit = PositionGetDouble(POSITION_PROFIT) * volumeRatio;
                              swap = PositionGetDouble(POSITION_SWAP) * volumeRatio;
                              commission = GetPositionCommission(newTicket) * volumeRatio;
                           }

                           string eventJson = BuildModifiedEventJson(originalMasterTicket, sl, tp, openPrice, false, remainingVolume);
                           SendEventWithRetry(eventJson, "modified (partial close) " + IntegerToString(originalMasterTicket));

                           UpdateOrderState(newTicket,
                                          PositionGetDouble(POSITION_PRICE_OPEN),
                                          PositionGetDouble(POSITION_SL),
                                          PositionGetDouble(POSITION_TP),
                                          remainingVolume,
                                          originalMasterTicket);
                           break;
                        }
                     }
                  }
               }

               if(isPartialClose) {

                  ulong newTicketFound = 0;
                  double remainingVolumeFound = 0;
                  for(int i = 0; i < PositionsTotal(); i++) {
                     string sym = PositionGetSymbol(i);
                     if(sym == posSymbol) {
                        int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
                        if(posMagic == originalMagic) {
                           string posComment = PositionGetString(POSITION_COMMENT);
                           if(StringFind(posComment, "from #") >= 0) {
                              newTicketFound = PositionGetInteger(POSITION_TICKET);
                              remainingVolumeFound = PositionGetDouble(POSITION_VOLUME);
                              break;
                           }
                        }
                     }
                  }

                  AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
               } else {
                  AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
               }
            } else {
               AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
            }
      } else {
         int errorCode = GetLastError();
         string errorMsg = StringFormat("PositionClose failed (error=%d)", errorCode);
         AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
      }
      return;
   }

   bool orderFound = SelectOrderByTicket(masterTicket);
   if(!orderFound && masterTicket > 0) {
      for(int i = 0; i < OrdersTotal(); i++) {
         ulong ot = OrderGetTicket(i);
         if(ot == 0 || !OrderSelect(ot)) continue;
         ulong mappedOriginal = GetOriginalTicket(ot);
         if(mappedOriginal == masterTicket || ot == masterTicket) {
            orderFound = true;
            break;
         }
      }
   }

   if(orderFound) {

      ulong realOrderTicket = OrderGetInteger(ORDER_TICKET);

      bool ok = g_trade.OrderDelete(realOrderTicket);
      if(ok) {
         AckCommand(commandId, 0, "ok", "{\"success\":true,\"error\":null}");
      } else {
         int errorCode = GetLastError();
         string errorMsg = StringFormat("OrderDelete failed (error=%d)", errorCode);
         AckCommand(commandId, -1, errorMsg, "{\"success\":false,\"error\":\"" + errorMsg + "\"}");
      }
      return;
   }

   AckCommand(commandId, -1, "ticket not found", "{\"success\":false,\"error\":\"ticket not found\"}");
}

ulong GetSnapshotMasterTicket(const string elem) {
   ulong masterTicket = (ulong)BridgeJsonGetLong(elem, "ticket", 0);
   if(masterTicket == 0) masterTicket = (ulong)BridgeJsonGetLong(elem, "order_id", 0);
   return masterTicket;
}

bool CommentReferencesMaster(const string comment, const string masterStr) {
   if(StringLen(comment) == 0 || StringLen(masterStr) == 0) return false;
   if(comment == masterStr) return true;
   if(StringFind(comment, "from #" + masterStr) >= 0) return true;
   if(StringFind(comment, "FROM #" + masterStr) >= 0) return true;
   return false;
}

bool PendingBelongsToMaster(const ulong masterTicket) {
   if(masterTicket == 0) return false;
   string masterStr = IntegerToString(masterTicket);
   int masterInt = (int)masterTicket;

   int orderMagic = (int)OrderGetInteger(ORDER_MAGIC);
   if(orderMagic != 0 && orderMagic == masterInt) return true;

   string comment = OrderGetString(ORDER_COMMENT);
   if(CommentReferencesMaster(comment, masterStr)) return true;

   ulong parent = ExtractParentTicketFromComment(comment);
   if(parent > 0 && parent == masterTicket) return true;

   ulong orderTicket = (ulong)OrderGetInteger(ORDER_TICKET);
   if(orderTicket > 0) {
      ulong mapped = GetOriginalTicket(orderTicket);
      if(mapped > 0 && mapped == masterTicket) return true;
   }

   return false;
}

bool PositionBelongsToMaster(const ulong masterTicket) {
   if(masterTicket == 0) return false;
   string masterStr = IntegerToString(masterTicket);
   int masterInt = (int)masterTicket;

   int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
   if(posMagic != 0 && posMagic == masterInt) return true;

   string comment = PositionGetString(POSITION_COMMENT);
   if(CommentReferencesMaster(comment, masterStr)) return true;

   ulong parent = ExtractParentTicketFromComment(comment);
   if(parent > 0 && parent == masterTicket) return true;

   ulong posTicket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(posTicket > 0) {
      ulong mapped = GetOriginalTicket(posTicket);
      if(mapped > 0 && mapped == masterTicket) return true;
   }

   return false;
}

void HandleReconcileSnapshot(const long commandId, const string payload) {
   if(StringLen(payload) == 0) {
      if(commandId != 0) AckCommand(commandId, -1, "empty payload", "{\"success\":false}");
      return;
   }

   // Order gate: ignore stale / out-of-order / replayed snapshots. Only act on a snapshot
   // newer than the last one we applied, so close-on-absence is always against current
   // master state. A new master session (restart) is always accepted.
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

   const long snapCmdId = 0;


   bool snapshotValid = (StringFind(payload, "\"open_positions\"") >= 0 && StringFind(payload, "\"pending_orders\"") >= 0);

   bool exactMatch = (StringFind(payload, "\"exact_match\":true") >= 0);
   if(exactMatch && snapshotValid) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong xmTicket = PositionGetTicket(i);
         if(xmTicket == 0) continue;
         if(!PositionSelectByTicket(xmTicket)) continue;
         if((int)PositionGetInteger(POSITION_MAGIC) != 0) continue;
         bool belongsToAnyMaster = false;
         for(int k = 0; k < nPos && !belongsToAnyMaster; k++) {
            ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(openPositionsArr, k));
            if(PositionBelongsToMaster(mt)) belongsToAnyMaster = true;
         }
         for(int k = 0; k < nOrd && !belongsToAnyMaster; k++) {
            ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(pendingOrdersArr, k));
            if(PositionBelongsToMaster(mt)) belongsToAnyMaster = true;
         }
         if(belongsToAnyMaster) continue;
         if(g_trade.PositionClose(xmTicket)) {
            RemoveOrderState(xmTicket);
            UnmarkCopierEntry(xmTicket);
         }
      }
      for(int i = OrdersTotal() - 1; i >= 0; i--) {
         ulong xmTicket = OrderGetTicket(i);
         if(xmTicket == 0) continue;
         if(!OrderSelect(xmTicket)) continue;
         if((int)OrderGetInteger(ORDER_MAGIC) != 0) continue;
         bool belongsToAnyMaster = false;
         for(int k = 0; k < nPos && !belongsToAnyMaster; k++) {
            ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(openPositionsArr, k));
            if(PendingBelongsToMaster(mt)) belongsToAnyMaster = true;
         }
         for(int k = 0; k < nOrd && !belongsToAnyMaster; k++) {
            ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(pendingOrdersArr, k));
            if(PendingBelongsToMaster(mt)) belongsToAnyMaster = true;
         }
         if(belongsToAnyMaster) continue;
         if(g_trade.OrderDelete(xmTicket)) {
            RemoveOrderState(xmTicket);
            UnmarkCopierEntry(xmTicket);
         }
      }
   }

   if(snapshotValid) {
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
      string posComment = PositionGetString(POSITION_COMMENT);
      if(posMagic == 0 && StringLen(posComment) == 0) continue;

      ulong matchedMaster = 0;
      for(int k = 0; k < nPos && matchedMaster == 0; k++) {
         ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(openPositionsArr, k));
         if(PositionBelongsToMaster(mt)) matchedMaster = mt;
      }
      if(matchedMaster != 0) continue;

      for(int k = 0; k < nOrd && matchedMaster == 0; k++) {
         ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(pendingOrdersArr, k));
         if(PositionBelongsToMaster(mt)) matchedMaster = mt;
      }
      if(matchedMaster != 0) continue;

      ulong cancelTicket = (posMagic != 0) ? (ulong)posMagic : GetOriginalTicket(ticket);
      if(cancelTicket == 0) continue;
      string cancelPayload = "{\"ticket\":" + IntegerToString(cancelTicket) + "}";
      HandleCancel(snapCmdId, cancelPayload);
   }


   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket == 0) continue;
      if(!OrderSelect(orderTicket)) continue;
      int ordMagic = (int)OrderGetInteger(ORDER_MAGIC);
      string ordComment = OrderGetString(ORDER_COMMENT);
      if(ordMagic == 0 && StringLen(ordComment) == 0) continue;

      ulong matchedMaster = 0;
      for(int k = 0; k < nOrd && matchedMaster == 0; k++) {
         ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(pendingOrdersArr, k));
         if(PendingBelongsToMaster(mt)) matchedMaster = mt;
      }
      if(matchedMaster != 0) continue;

      for(int k = 0; k < nPos && matchedMaster == 0; k++) {
         ulong mt = GetSnapshotMasterTicket(BridgeJsonArrayElement(openPositionsArr, k));
         if(PendingBelongsToMaster(mt)) matchedMaster = mt;
      }
      if(matchedMaster != 0) continue;

      ulong cancelTicket = (ordMagic != 0) ? (ulong)ordMagic : GetOriginalTicket(orderTicket);
      if(cancelTicket == 0) continue;
      string cancelPayload = "{\"ticket\":" + IntegerToString(cancelTicket) + "}";
      HandleCancel(snapCmdId, cancelPayload);
   }
   }

   // Snapshot freshness is evaluated per-item via age_seconds on each open_positions/pending_orders entry.
   for(int k = 0; k < nPos; k++) {
      string elem = BridgeJsonArrayElement(openPositionsArr, k);
      ulong masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket == 0) continue;
      bool haveIt = false;
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == "") continue;
         if(PositionBelongsToMaster(masterTicket)) { haveIt = true; break; }
      }
      if(haveIt) continue;
      string typeStr = ToLowerString(BridgeJsonGetString(elem, "type", "market"));
      if(typeStr != "market") continue;
      string symbol = BridgeJsonGetString(elem, "symbol", "");
      string side = ToLowerString(BridgeJsonGetString(elem, "side", "buy"));
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
      string createPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"symbol\":" + BridgeJsonQuote(symbol) + ",\"type\":\"market\",\"side\":" + BridgeJsonQuote(side) + ",\"volume\":" + DoubleToString(volume, 2) + ",\"price\":0,\"sl\":" + DoubleToString(sl, 5) + ",\"tp\":" + DoubleToString(tp, 5) + ",\"age_seconds\":" + IntegerToString((int)posAgeSeconds) + "}";
      HandleCreate(snapCmdId, createPayload);
   }

   for(int k = 0; k < nOrd; k++) {
      string elem = BridgeJsonArrayElement(pendingOrdersArr, k);
      ulong masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket == 0) continue;
      bool haveIt = false;
      for(int i = 0; i < OrdersTotal(); i++) {
         ulong ot = OrderGetTicket(i);
         if(ot == 0) continue;
         if(!OrderSelect(ot)) continue;
         if(PendingBelongsToMaster(masterTicket)) { haveIt = true; break; }
      }
      if(haveIt) continue;

      bool havePosition = false;
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == "") continue;
         if(PositionBelongsToMaster(masterTicket)) { havePosition = true; break; }
      }
      if(havePosition) continue;
      string typeStr = ToLowerString(BridgeJsonGetString(elem, "type", "limit"));
      string symbol = BridgeJsonGetString(elem, "symbol", "");
      string side = ToLowerString(BridgeJsonGetString(elem, "side", "buy"));
      double volume = BridgeJsonGetDouble(elem, "volume", 0);
      double price = BridgeJsonGetDouble(elem, "price", 0);
      double sl = BridgeJsonGetDouble(elem, "sl", 0);
      double tp = BridgeJsonGetDouble(elem, "tp", 0);
      if(symbol == "" || volume <= 0 || (typeStr != "limit" && typeStr != "stop")) continue;
      if(price <= 0) continue;
      string createPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"symbol\":" + BridgeJsonQuote(symbol) + ",\"type\":" + BridgeJsonQuote(typeStr) + ",\"side\":" + BridgeJsonQuote(side) + ",\"volume\":" + DoubleToString(volume, 2) + ",\"price\":" + DoubleToString(price, 5) + ",\"sl\":" + DoubleToString(sl, 5) + ",\"tp\":" + DoubleToString(tp, 5) + "}";
      HandleCreate(snapCmdId, createPayload);
   }

   for(int k = 0; k < nPos; k++) {
      string elem = BridgeJsonArrayElement(openPositionsArr, k);
      ulong masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket == 0) continue;
      ulong slaveTicket = 0;
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionGetSymbol(i) == "") continue;
         if(PositionBelongsToMaster(masterTicket)) { slaveTicket = PositionGetInteger(POSITION_TICKET); break; }
      }
      if(slaveTicket == 0) continue;
      if(!PositionSelectByTicket(slaveTicket)) continue;
      string snapSymbolPos = BridgeJsonGetString(elem, "symbol", "");
      string snapSidePos = ToLowerString(BridgeJsonGetString(elem, "side", "buy"));
      string curSymbolPos = PositionGetString(POSITION_SYMBOL);
      string curSidePos = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) ? "sell" : "buy";
      double snapSl = BridgeJsonGetDouble(elem, "sl", 0);
      double snapTp = BridgeJsonGetDouble(elem, "tp", 0);
      double snapVol = BridgeJsonGetDouble(elem, "volume", 0);
      snapVol = NormalizeVolumeForSymbolMT5(snapSymbolPos, snapVol);
      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      double curVol = PositionGetDouble(POSITION_VOLUME);      bool symbolEqualPos = (snapSymbolPos == curSymbolPos);
      bool sideEqualPos = (snapSidePos == curSidePos);
      if(symbolEqualPos && sideEqualPos && MathAbs(snapSl - curSl) < 0.00001 && MathAbs(snapTp - curTp) < 0.00001 && MathAbs(snapVol - curVol) < 0.00001) continue;
      if((!symbolEqualPos && snapSymbolPos != "") || !sideEqualPos) {
         while(true) {
            ulong toClose = 0;
            for(int i = 0; i < PositionsTotal(); i++) {
               if(PositionGetSymbol(i) == "") continue;
               if(PositionBelongsToMaster(masterTicket)) { toClose = PositionGetInteger(POSITION_TICKET); break; }
            }
            if(toClose == 0) break;
            if(!PositionSelectByTicket(toClose)) break;
            if(!g_trade.PositionClose(toClose)) break;
         }
         {
            long posAgeSeconds = (long)BridgeJsonGetLong(elem, "age_seconds", -1);
            if(posAgeSeconds < 0) {
            } else if(posAgeSeconds > MARKET_ORDER_MAX_AGE_SEC) {
            } else {
               string createPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"symbol\":" + BridgeJsonQuote(snapSymbolPos) + ",\"type\":\"market\",\"side\":" + BridgeJsonQuote(snapSidePos) + ",\"volume\":" + DoubleToString(snapVol, 2) + ",\"price\":0,\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"age_seconds\":" + IntegerToString((int)posAgeSeconds) + "}";
               HandleCreate(snapCmdId, createPayload);
            }
         }
      } else {
         string modPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"volume\":" + DoubleToString(snapVol, 2) + "}";
         HandleModify(snapCmdId, modPayload);
      }
   }

   for(int k = 0; k < nOrd; k++) {
      string elem = BridgeJsonArrayElement(pendingOrdersArr, k);
      ulong masterTicket = GetSnapshotMasterTicket(elem);
      if(masterTicket == 0) continue;
      ulong slaveTicket = 0;
      for(int i = 0; i < OrdersTotal(); i++) {
         ulong ot = OrderGetTicket(i);
         if(ot == 0) continue;
         if(!OrderSelect(ot)) continue;
         if(PendingBelongsToMaster(masterTicket)) { slaveTicket = ot; break; }
      }
      if(slaveTicket == 0) continue;
      if(!OrderSelect(slaveTicket)) continue;
      string snapSymbolOrd = BridgeJsonGetString(elem, "symbol", "");
      string typeStrOrd = ToLowerString(BridgeJsonGetString(elem, "type", "limit"));
      string sideOrd = ToLowerString(BridgeJsonGetString(elem, "side", "buy"));
      string curSymbolOrd = OrderGetString(ORDER_SYMBOL);
      double snapPrice = BridgeJsonGetDouble(elem, "price", 0);
      double snapSl = BridgeJsonGetDouble(elem, "sl", 0);
      double snapTp = BridgeJsonGetDouble(elem, "tp", 0);
      double snapVol = BridgeJsonGetDouble(elem, "volume", 0);
      snapVol = NormalizeVolumeForSymbolMT5(snapSymbolOrd, snapVol);
      double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double curSl = OrderGetDouble(ORDER_SL);
      double curTp = OrderGetDouble(ORDER_TP);
      double curVol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      ENUM_ORDER_TYPE curTypeOrd = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      ENUM_ORDER_TYPE snapTypeOrd = ORDER_TYPE_BUY_LIMIT;
      bool validSnapType = true;
      if(typeStrOrd == "limit") {
         snapTypeOrd = (sideOrd == "sell") ? ORDER_TYPE_SELL_LIMIT : ORDER_TYPE_BUY_LIMIT;
      } else if(typeStrOrd == "stop") {
         snapTypeOrd = (sideOrd == "sell") ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
      } else {
         validSnapType = false;
      }
      bool symbolEqualOrd = (snapSymbolOrd == curSymbolOrd);
      bool typeEqualOrd = (validSnapType && curTypeOrd == snapTypeOrd);
      if(symbolEqualOrd && typeEqualOrd && MathAbs(snapPrice - curPrice) < 0.00001 && MathAbs(snapSl - curSl) < 0.00001 && MathAbs(snapTp - curTp) < 0.00001 && MathAbs(snapVol - curVol) < 0.00001) continue;
      if((!symbolEqualOrd && snapSymbolOrd != "") || !typeEqualOrd) {
         HandleCancel(snapCmdId, "{\"ticket\":" + IntegerToString((int)masterTicket) + "}");
         string createPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"symbol\":" + BridgeJsonQuote(snapSymbolOrd) + ",\"type\":" + BridgeJsonQuote(typeStrOrd) + ",\"side\":" + BridgeJsonQuote(sideOrd) + ",\"volume\":" + DoubleToString(snapVol, 2) + ",\"price\":" + DoubleToString(snapPrice, 5) + ",\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + "}";
         HandleCreate(snapCmdId, createPayload);
      } else {
         string modPayload = "{\"ticket\":" + IntegerToString((int)masterTicket) + ",\"price\":" + DoubleToString(snapPrice, 5) + ",\"sl\":" + DoubleToString(snapSl, 5) + ",\"tp\":" + DoubleToString(snapTp, 5) + ",\"volume\":" + DoubleToString(snapVol, 2) + "}";
         HandleModify(snapCmdId, modPayload);
      }
   }

   if(commandId != 0) {
      AckCommand(commandId, 0, "ok", "{\"success\":true}");
   }
}

int FindOrderStateIndex(ulong ticket) {
   int size = ArraySize(g_orderStates);
   int i;
   for(i = 0; i < size; i++) {
      if(g_orderStates[i].ticket == ticket) return i;
   }
   return -1;
}

int FindPositionLifecycleStateIndex(const ulong positionTicket) {
   int size = ArraySize(g_positionLifecycleStates);
   for(int i = 0; i < size; i++) {
      if(g_positionLifecycleStates[i].positionTicket == positionTicket) return i;
   }
   return -1;
}

void SetPositionLifecycleState(const ulong positionTicket, const ulong lifecycleTicket) {
   int idx = FindPositionLifecycleStateIndex(positionTicket);
   if(idx < 0) {
      int size = ArraySize(g_positionLifecycleStates);
      ArrayResize(g_positionLifecycleStates, size + 1);
      idx = size;
      g_positionLifecycleStates[idx].positionTicket = positionTicket;
   }
   g_positionLifecycleStates[idx].lifecycleTicket = lifecycleTicket;
}

ulong GetOriginalTicket(ulong currentTicket) {
   int size = ArraySize(g_ticketMaps);
   int i;
   for(i = 0; i < size; i++) {
      if(g_ticketMaps[i].currentTicket == currentTicket) {
         return g_ticketMaps[i].originalTicket;
      }
   }
   return currentTicket;
}

string CopierEntriesFilePath() {
   return "IPTRADE\\copier_entries_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
}

int FindCopierEntryIndex(const ulong slaveTicket) {
   int size = ArraySize(g_copierEntries);
   for(int i = 0; i < size; i++) {
      if(g_copierEntries[i].slaveTicket == slaveTicket) return i;
   }
   return -1;
}

bool IsCopierEntry(const ulong slaveTicket) {
   return FindCopierEntryIndex(slaveTicket) >= 0;
}

void SaveCopierEntries() {
   string path = CopierEntriesFilePath();
   int handle = FileOpen(path, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ, ';');
   if(handle == INVALID_HANDLE) return;
   int size = ArraySize(g_copierEntries);
   for(int i = 0; i < size; i++) {
      FileWrite(handle, (long)g_copierEntries[i].slaveTicket, (long)g_copierEntries[i].masterTicket);
   }
   FileClose(handle);
}

void MarkCopierEntry(const ulong slaveTicket, const ulong masterTicket) {
   if(slaveTicket == 0 || masterTicket == 0) return;
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

void UnmarkCopierEntry(const ulong slaveTicket) {
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
      ulong slaveTicket = (ulong)StringToInteger(slaveStr);
      ulong masterTicket = (ulong)StringToInteger(masterStr);
      if(slaveTicket == 0 || masterTicket == 0) continue;
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
      ulong st = g_copierEntries[i].slaveTicket;
      bool exists = PositionSelectByTicket(st) || OrderSelect(st);
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

void RegisterTicketMap(ulong currentTicket, ulong originalTicket) {
   if(g_inSlaveCommand && currentTicket != originalTicket && currentTicket > 0 && originalTicket > 0) {
      MarkCopierEntry(currentTicket, originalTicket);
   }
   int size = ArraySize(g_ticketMaps);
   int i;
   for(i = 0; i < size; i++) {
      if(g_ticketMaps[i].currentTicket == currentTicket) {
         g_ticketMaps[i].originalTicket = originalTicket;
         return;
      }
   }
   ArrayResize(g_ticketMaps, size + 1);
   g_ticketMaps[size].currentTicket = currentTicket;
   g_ticketMaps[size].originalTicket = originalTicket;
}

ulong ExtractParentTicketFromComment(string comment) {
   int pos = StringFind(comment, "from #");
   if(pos < 0) pos = StringFind(comment, "FROM #");
   if(pos >= 0) {
      string ticketStr = StringSubstr(comment, pos + 6);
      string cleanTicket = "";
      int i;
      for(i = 0; i < StringLen(ticketStr); i++) {
         ushort c = StringGetCharacter(ticketStr, i);
         if(c >= '0' && c <= '9') {
            cleanTicket += CharToString((uchar)(c & 0xFF));
         } else {
            break;
         }
      }
      if(StringLen(cleanTicket) > 0) {
         return (ulong)StringToInteger(cleanTicket);
      }
   }
   return 0;
}

ulong GetOpeningOrderTicketForPosition(const ulong positionTicket) {
   if(positionTicket == 0) return 0;
   if(!HistorySelect(0, TimeCurrent())) return 0;

   int deals = HistoryDealsTotal();
   ulong openingOrder = 0;
   for(int i = deals - 1; i >= 0; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong dealPositionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPositionId != positionTicket) continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN) continue;

      ulong dealOrder = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
      if(dealOrder > 0) openingOrder = dealOrder;
   }

   return openingOrder;
}

ulong GetOrderThatFilledPosition(ulong positionTicket) {
   if(!HistorySelect(0, TimeCurrent())) return 0;
   int deals = HistoryDealsTotal();
   int i;
   for(i = deals - 1; i >= 0 && i > deals - 200; i--) {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      ulong dealPosId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      if(dealPosId != positionTicket) continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN) continue;
      return (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   }
   return 0;
}

ulong ResolveLifecycleTicketForPosition(const ulong positionTicket, const string positionComment = "") {
   if(positionTicket == 0) return 0;

   int cacheIdx = FindPositionLifecycleStateIndex(positionTicket);
   if(cacheIdx >= 0 && g_positionLifecycleStates[cacheIdx].lifecycleTicket > 0) {
      return g_positionLifecycleStates[cacheIdx].lifecycleTicket;
   }

   ulong lifecycleTicket = GetOriginalTicket(positionTicket);
   if(lifecycleTicket == 0) lifecycleTicket = positionTicket;

   string comment = positionComment;
   if(StringLen(comment) == 0 && PositionSelectByTicket(positionTicket)) {
      comment = PositionGetString(POSITION_COMMENT);
   }

   ulong parentPositionTicket = ExtractParentTicketFromComment(comment);
   if(parentPositionTicket > 0 && parentPositionTicket != positionTicket) {
      ulong parentOpeningOrder = GetOpeningOrderTicketForPosition(parentPositionTicket);
      if(parentOpeningOrder > 0) lifecycleTicket = parentOpeningOrder;
      else lifecycleTicket = parentPositionTicket;
   }

   if(lifecycleTicket == positionTicket || lifecycleTicket == 0) {
      // Check copier entries first (persisted to disk, survives restarts).
      // This correctly maps slave position ticket → master ticket, which
      // GetOpeningOrderTicketForPosition cannot do (it returns the slave's
      // own order ticket, not the master's ticket).
      int ceIdx = FindCopierEntryIndex(positionTicket);
      if(ceIdx >= 0 && g_copierEntries[ceIdx].masterTicket > 0) {
         lifecycleTicket = g_copierEntries[ceIdx].masterTicket;
      } else {
         ulong openingOrder = GetOpeningOrderTicketForPosition(positionTicket);
         if(openingOrder > 0) lifecycleTicket = openingOrder;
      }
   }

   if(lifecycleTicket == 0) lifecycleTicket = positionTicket;

   RegisterTicketMap(positionTicket, lifecycleTicket);
   SetPositionLifecycleState(positionTicket, lifecycleTicket);
   return lifecycleTicket;
}

ulong ExtractChildTicketFromComment(string comment) {
   int pos = StringFind(comment, "to #");
   if(pos < 0) pos = StringFind(comment, "TO #");
   if(pos >= 0) {
      string ticketStr = StringSubstr(comment, pos + 4);
      string cleanTicket = "";
      int i;
      for(i = 0; i < StringLen(ticketStr); i++) {
         ushort c = StringGetCharacter(ticketStr, i);
         if(c >= '0' && c <= '9') {
            cleanTicket += CharToString((uchar)(c & 0xFF));
         } else {
            break;
         }
      }
      if(StringLen(cleanTicket) > 0) {
         return (ulong)StringToInteger(cleanTicket);
      }
   }
   return 0;
}

void UpdateOrderState(ulong ticket, double price, double sl, double tp, double lots, ulong originalTicket = 0) {
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
}

void RemoveOrderState(ulong ticket) {
   int idx = FindOrderStateIndex(ticket);
   if(idx >= 0) {
      int size = ArraySize(g_orderStates);
      int i;
      for(i = idx; i < size - 1; i++) {
         g_orderStates[i] = g_orderStates[i + 1];
      }
      ArrayResize(g_orderStates, size - 1);
   }
   UnmarkCopierEntry(ticket);
}

void SendEventWithRetry(const string eventJson, const string description) {
   int maxRetries = 3;
   int attempts = 0;
   int result = -1;

   while(attempts < maxRetries) {
      attempts++;
      result = PushLocalEvent(eventJson);

      if(result == 1) {
         if(attempts > 1) {
         } else {
         }
         return;
      }

      if(result == -2) {
         if(attempts == 1) {
         }
         return;
      }

      if(result == -4) {
         if(attempts == 1) {
         }
         return;
      }

      if(attempts < maxRetries) {
      }
   }

}

void ProcessTradeEvents() {
   static bool isReconciling = false;
   if(isReconciling) return;
   
   isReconciling = true;
   ulong activeTickets[];
   ArrayResize(activeTickets, 0);

   int i;

   for(i = PositionsTotal() - 1; i >= 0; i--) {
      string symbol = PositionGetSymbol(i);
      if(symbol == "") continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      string comment = PositionGetString(POSITION_COMMENT);

      int size = ArraySize(activeTickets);
      ArrayResize(activeTickets, size + 1);
      activeTickets[size] = ticket;

      if(StringLen(comment) > 0 && StringToInteger(comment) == (int)magic && magic > 0) continue;

      double currentPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);
      double currentLots = PositionGetDouble(POSITION_VOLUME);

      int stateIdx = FindOrderStateIndex(ticket);
      bool isNew = !ArrayContainsU(g_reportedPositions, ticket);

      if(isNew) {
         ulong creatingOrder = GetOrderThatFilledPosition(ticket);
         bool isPendingOpened = (creatingOrder > 0 && (FindOrderStateIndex(creatingOrder) >= 0 || ArrayContainsU(g_reportedOrders, creatingOrder)));
         if(isPendingOpened) {
            ulong origTicket = creatingOrder;
            int ordIdx = FindOrderStateIndex(creatingOrder);
            if(ordIdx >= 0 && g_orderStates[ordIdx].originalTicket > 0) origTicket = g_orderStates[ordIdx].originalTicket;
            if(origTicket == 0) origTicket = ResolveLifecycleTicketForPosition(ticket, comment);
            ArrayPushU(g_reportedPositions, ticket);
            RegisterTicketMap(ticket, origTicket);
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, origTicket);
         } else {
            datetime posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
            long posAgeSec = (long)(TimeTradeServer() - posOpenTime);
            if(posAgeSec < 0) posAgeSec = 0;
            ulong reportTicket = ResolveLifecycleTicketForPosition(ticket, comment);
            string eventJson = BuildPositionEventJson("placed", reportTicket, symbol, (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE), currentLots, currentPrice, currentSL, currentTP, comment, magic, posAgeSec);
            SendEventWithRetry(eventJson, "new position " + IntegerToString(ticket));
            ArrayPushU(g_reportedPositions, ticket);
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, reportTicket);
         }
      } else if(stateIdx >= 0) {
         OrderState prevState = g_orderStates[stateIdx];

         if(MathAbs(prevState.lots - currentLots) > 0.00001 && currentLots < prevState.lots) {
            ulong originalTicket = prevState.originalTicket > 0 ? prevState.originalTicket : ticket;
            double closedVolume = prevState.lots - currentLots;

            ulong newTicket = ticket;
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
            datetime closeTime = TimeCurrent();
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            double profit = 0;
            double swap = 0;
            double commission = 0;
            if(prevState.lots > 0) {
               double volumeRatio = closedVolume / prevState.lots;
               profit = PositionGetDouble(POSITION_PROFIT) * volumeRatio;
               swap = PositionGetDouble(POSITION_SWAP) * volumeRatio;
               commission = GetPositionCommission(ticket) * volumeRatio;
            }

            for(int k = 0; k < PositionsTotal(); k++) {
               if(PositionGetSymbol(k) == symbol) {
                  string posComment = PositionGetString(POSITION_COMMENT);
                  if(StringFind(posComment, "from #" + IntegerToString(ticket)) >= 0) {
                     newTicket = PositionGetInteger(POSITION_TICKET);
                     break;
                  }
               }
            }

            string eventJson = BuildModifiedEventJson(originalTicket, currentSL, currentTP, currentPrice, false, currentLots);
            SendEventWithRetry(eventJson, "modified (partial close) " + IntegerToString(originalTicket));

            for(int k = 0; k < PositionsTotal(); k++) {
               if(PositionGetSymbol(k) == symbol) {
                  string posComment = PositionGetString(POSITION_COMMENT);
                  if(StringFind(posComment, "from #" + IntegerToString(ticket)) >= 0) {
                     ulong newTicket = PositionGetInteger(POSITION_TICKET);
                     RegisterTicketMap(newTicket, originalTicket);
                     UpdateOrderState(newTicket, currentPrice, currentSL, currentTP, currentLots, originalTicket);
                     break;
                  }
               }
            }

            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, originalTicket);
         } else {
            bool hasChanges = false;

            if(MathAbs(prevState.sl - currentSL) > 0.00001) {
               hasChanges = true;
            }
            if(MathAbs(prevState.tp - currentTP) > 0.00001) {
               hasChanges = true;
            }

            if(hasChanges) {
               ulong reportTicket = prevState.originalTicket > 0 ? prevState.originalTicket : ticket;
               string eventJson = BuildModifiedEventJson(reportTicket, currentSL, currentTP, currentPrice, false, currentLots);
               SendEventWithRetry(eventJson, "modified position " + IntegerToString(reportTicket));
               UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, reportTicket);
            } else {
               ulong origTicket = ResolveLifecycleTicketForPosition(ticket, comment);
               UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, origTicket);
            }
         }
      } else {
         ulong origTicket = ResolveLifecycleTicketForPosition(ticket, comment);
         UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, origTicket);
      }
   }

   for(i = OrdersTotal() - 1; i >= 0; i--) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      long magic = (long)OrderGetInteger(ORDER_MAGIC);
      string comment = OrderGetString(ORDER_COMMENT);

      int size = ArraySize(activeTickets);
      ArrayResize(activeTickets, size + 1);
      activeTickets[size] = ticket;

      if(StringLen(comment) > 0 && StringToInteger(comment) == (int)magic && magic > 0) continue;

      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_SELL) {
         continue;
      }

      double currentPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double currentSL = OrderGetDouble(ORDER_SL);
      double currentTP = OrderGetDouble(ORDER_TP);
      double currentLots = OrderGetDouble(ORDER_VOLUME_CURRENT);

      int stateIdx = FindOrderStateIndex(ticket);
      bool isNew = !ArrayContainsU(g_reportedOrders, ticket);

      if(isNew) {
         datetime ordSetupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
         long orderAgeSec = (long)(TimeTradeServer() - ordSetupTime);
         if(orderAgeSec < 0) orderAgeSec = 0;
         string eventJson = BuildOrderEventJson("placed", ticket, OrderGetString(ORDER_SYMBOL), orderType, currentLots, currentPrice, currentSL, currentTP, comment, magic, orderAgeSec);
         SendEventWithRetry(eventJson, "new order " + IntegerToString(ticket));
         ArrayPushU(g_reportedOrders, ticket);
         UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots);
      } else if(stateIdx >= 0) {
         OrderState prevState = g_orderStates[stateIdx];
         bool hasChanges = false;

         if(MathAbs(prevState.price - currentPrice) > 0.00001) {
            hasChanges = true;
         }

         if(MathAbs(prevState.sl - currentSL) > 0.00001) {
            hasChanges = true;
         }
         if(MathAbs(prevState.tp - currentTP) > 0.00001) {
            hasChanges = true;
         }

         if(MathAbs(prevState.lots - currentLots) > 0.00001) {
            hasChanges = true;
         }

         if(hasChanges) {
            ulong reportTicket = prevState.originalTicket > 0 ? prevState.originalTicket : ticket;
            string eventJson = BuildModifiedEventJson(reportTicket, currentSL, currentTP, currentPrice, true, currentLots);
            SendEventWithRetry(eventJson, "modified order " + IntegerToString(reportTicket));
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, reportTicket);
         } else {
            ulong reportTicket = prevState.originalTicket > 0 ? prevState.originalTicket : ticket;
            UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots, reportTicket);
         }
      } else {
         UpdateOrderState(ticket, currentPrice, currentSL, currentTP, currentLots);
      }
   }

   for(i = ArraySize(g_orderStates) - 1; i >= 0; i--) {
      ulong ticket = g_orderStates[i].ticket;

      bool stillActive = false;
      int j;
      for(j = 0; j < ArraySize(activeTickets); j++) {
         if(activeTickets[j] == ticket) {
            stillActive = true;
            break;
         }
      }

      if(!stillActive) {

         bool isPartialCloseReplacement = false;
         string searchFrom = "from #" + IntegerToString(ticket);
         for(int k = 0; k < ArraySize(activeTickets); k++) {
            if(PositionSelectByTicket(activeTickets[k])) {
               string activeComment = PositionGetString(POSITION_COMMENT);
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

         if(!ArrayContainsU(g_reportedDeals, ticket)) {
            int stateIdx = FindOrderStateIndex(ticket);
            ulong reportTicket = ticket;
            if(stateIdx >= 0 && g_orderStates[stateIdx].originalTicket > 0) {
               reportTicket = g_orderStates[stateIdx].originalTicket;
            }

            bool wasPosition = ArrayContainsU(g_reportedPositions, ticket);

            if(wasPosition) {
               if(HistorySelect(0, TimeCurrent())) {
                  int deals = HistoryDealsTotal();
                  bool found = false;
                  for(j = deals - 1; j >= 0 && j > deals - 200; j--) {
                     ulong dealTicket = HistoryDealGetTicket(j);
                     ulong dealPosition = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
                     if(dealPosition == ticket) {
                        ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
                        if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY) {
                           string eventJson = BuildHistoryDealEventJson("closed", reportTicket, dealTicket);
                           SendEventWithRetry(eventJson, "closed position " + IntegerToString(reportTicket));
                           ArrayPushU(g_reportedDeals, ticket);
                           found = true;
                           break;
                        }
                     }
                  }
                  if(!found) {
                  }
               }
            } else {
               if(HistoryOrderSelect(ticket)) {
                  ENUM_ORDER_STATE orderState = (ENUM_ORDER_STATE)HistoryOrderGetInteger(ticket, ORDER_STATE);
                  if(orderState == ORDER_STATE_CANCELED || orderState == ORDER_STATE_REJECTED) {

                     string eventJson = "{";
                     eventJson += "\"event\":\"closed\",";
                     eventJson += StringFormat("\"ticket\":%I64u", reportTicket);
                     eventJson += "}";

                     SendEventWithRetry(eventJson, "closed order " + IntegerToString(reportTicket));
                     ArrayPushU(g_reportedDeals, ticket);
                  } else if(orderState == ORDER_STATE_FILLED) {
                  }
               }
            }
         }
         RemoveOrderState(ticket);
      }
   }
   
   isReconciling = false;
}

string BuildModifiedEventJson(const ulong ticket, const double sl, const double tp, const double price = 0, const bool isPending = false, const double volume = 0) {

   string json = "{";
   json += "\"event\":\"modified\",";
   json += StringFormat("\"ticket\":%I64u,", ticket);
   json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
   json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
   json += StringFormat("\"price\":%.5f,", price);
   json += StringFormat("\"volume\":%.2f", volume);
   json += "}";
   return json;
}

string BuildPositionEventJson(const string eventType, const ulong ticket, const string symbol, const ENUM_POSITION_TYPE posType,
                              const double volume, const double price, const double sl, const double tp,
                              const string comment, const long magic = 0, const long ageSeconds = 0) {
   string json = "{";
   json += "\"event\":" + BridgeJsonQuote(eventType) + ",";
   json += StringFormat("\"ticket\":%I64u,", ticket);
   json += "\"symbol\":" + BridgeJsonQuote(symbol) + ",";
   json += "\"type\":\"market\",";
   json += "\"side\":" + BridgeJsonQuote((posType == POSITION_TYPE_SELL) ? "sell" : "buy") + ",";
   json += StringFormat("\"volume\":%.2f,", volume);
   json += StringFormat("\"price\":%.5f,", price);
   json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
   json += (tp == 0) ? "\"tp\":null" : StringFormat("\"tp\":%.5f", tp);

   if(StringLen(comment) > 0) {
      json += ",\"comment\":" + BridgeJsonQuote(comment);
   }
   if(eventType == "placed" || eventType == "modified") {
      long age = (ageSeconds >= 0) ? ageSeconds : 0;
      json += StringFormat(",\"age_seconds\":%I64d", age);
   }
   json += "}";
   return json;
}

string BuildOrderEventJson(const string eventType, const ulong ticket, const string symbol, const ENUM_ORDER_TYPE orderType,
                          const double volume, const double price, const double sl, const double tp,
                          const string comment, const long magic = 0, const long ageSeconds = 0) {
   string json = "{";
   json += "\"event\":" + BridgeJsonQuote(eventType) + ",";
   json += StringFormat("\"ticket\":%I64u,", ticket);
   json += "\"symbol\":" + BridgeJsonQuote(symbol) + ",";
   json += "\"type\":" + BridgeJsonQuote(PendingTypeString(orderType)) + ",";
   json += "\"side\":" + BridgeJsonQuote((orderType == ORDER_TYPE_SELL || orderType == ORDER_TYPE_SELL_LIMIT || orderType == ORDER_TYPE_SELL_STOP) ? "sell" : "buy") + ",";
   json += StringFormat("\"volume\":%.2f,", volume);
   json += StringFormat("\"price\":%.5f,", price);
   json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
   json += (tp == 0) ? "\"tp\":null" : StringFormat("\"tp\":%.5f", tp);

   if(StringLen(comment) > 0) {
      json += ",\"comment\":" + BridgeJsonQuote(comment);
   }
   if(eventType == "placed" || eventType == "modified") {
      long age = (ageSeconds >= 0) ? ageSeconds : 0;
      json += StringFormat(",\"age_seconds\":%I64d", age);
   }
   json += "}";
   return json;
}

string BuildHistoryDealEventJson(const string eventType, const ulong ticketToReport, const ulong dealTicket) {

   string json = "{";
   json += "\"event\":\"closed\",";
   json += StringFormat("\"ticket\":%I64u", ticketToReport);
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
   account += StringFormat("\"login\":%I64d,", AccountInfoInteger(ACCOUNT_LOGIN));
   account += "\"server\":\"" + EscapeJsonString(g_effectiveServer) + "\",";
   account += "\"platform\":\"metatrader5\",";
   account += "\"name\":\"" + EscapeJsonString(AccountInfoString(ACCOUNT_NAME)) + "\",";
   account += "\"currency\":\"" + EscapeJsonString(AccountInfoString(ACCOUNT_CURRENCY)) + "\",";
   account += StringFormat("\"balance\":%.2f,", AccountInfoDouble(ACCOUNT_BALANCE));
   account += StringFormat("\"equity\":%.2f,", AccountInfoDouble(ACCOUNT_EQUITY));
   account += StringFormat("\"leverage\":%d}", AccountInfoInteger(ACCOUNT_LEVERAGE));
   return account;
}

string BuildSnapshotEventJson() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_snapSeq++;
   string json = "{";
   json += "\"event\":\"snapshot\",";
   json += StringFormat("\"session\":%I64d,\"seq\":%I64d,", g_snapSession, g_snapSeq);
   json += "\"platform\":\"metatrader5\",";
   json += "\"account\":{";
   json += StringFormat("\"account_id\":\"%I64d\",", AccountInfoInteger(ACCOUNT_LOGIN));
   json += "\"server\":\"" + EscapeJsonString(g_effectiveServer) + "\",";
   json += "\"currency\":\"" + EscapeJsonString(AccountInfoString(ACCOUNT_CURRENCY)) + "\",";
   json += StringFormat("\"balance\":%.2f,", balance);
   json += StringFormat("\"equity\":%.2f,", equity);
   json += StringFormat("\"unrealized_pnl\":%.2f,", equity - balance);
   json += StringFormat("\"leverage\":%d},", AccountInfoInteger(ACCOUNT_LEVERAGE));
   json += "\"open_positions\":[";
   int openCount = 0;
   int pendingCount = 0;
   bool posFirst = true;
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetSymbol(i) == "") continue;
      ulong ticket = PositionGetInteger(POSITION_TICKET);
      ulong reportTicket = ResolveLifecycleTicketForPosition(ticket, PositionGetString(POSITION_COMMENT));
      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      long ageSec = (long)(TimeTradeServer() - openTime);
      if(ageSec < 0) ageSec = 0;
      if(!posFirst) json += ",";
      posFirst = false;
      openCount++;
      json += "{";
      json += StringFormat("\"ticket\":%I64u,", reportTicket);
      json += "\"symbol\":" + BridgeJsonQuote(PositionGetString(POSITION_SYMBOL)) + ",";
      json += "\"type\":\"market\",";
      json += "\"side\":" + BridgeJsonQuote((pt == POSITION_TYPE_SELL) ? "sell" : "buy") + ",";
      json += StringFormat("\"volume\":%.2f,", vol);
      json += StringFormat("\"open_price\":%.5f,", openPrice);
      json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
      json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
      json += StringFormat("\"age_seconds\":%I64d,", ageSec);
      json += StringFormat("\"profit\":%.2f", PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) + PositionGetDouble(POSITION_COMMISSION));
      json += "}";
   }
   json += "],";
   json += "\"pending_orders\":[";
   bool ordFirst = true;
   for(int i = 0; i < OrdersTotal(); i++) {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      ulong reportTicket = GetOriginalTicket(ticket);
      if(reportTicket == 0) reportTicket = ticket;
      ulong parentFromComment = ExtractParentTicketFromComment(OrderGetString(ORDER_COMMENT));
      if(parentFromComment > 0 && parentFromComment != ticket) {
         reportTicket = parentFromComment;
      }
      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot == ORDER_TYPE_BUY || ot == ORDER_TYPE_SELL) continue;
      string typeStr = (ot == ORDER_TYPE_BUY_LIMIT || ot == ORDER_TYPE_SELL_LIMIT) ? "limit" : "stop";
      double vol = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double sl = OrderGetDouble(ORDER_SL);
      double tp = OrderGetDouble(ORDER_TP);
      datetime ordSetupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      long ordAgeSec = (long)(TimeTradeServer() - ordSetupTime);
      if(ordAgeSec < 0) ordAgeSec = 0;
      if(!ordFirst) json += ",";
      ordFirst = false;
      pendingCount++;
      json += "{";
      json += StringFormat("\"ticket\":%I64u,", reportTicket);
      json += "\"symbol\":" + BridgeJsonQuote(OrderGetString(ORDER_SYMBOL)) + ",";
      json += "\"type\":" + BridgeJsonQuote(typeStr) + ",";
      json += "\"side\":" + BridgeJsonQuote((ot == ORDER_TYPE_SELL_LIMIT || ot == ORDER_TYPE_SELL_STOP || ot == ORDER_TYPE_SELL_STOP_LIMIT) ? "sell" : "buy") + ",";
      json += StringFormat("\"volume\":%.2f,", vol);
      json += StringFormat("\"price\":%.5f,", price);
      json += (sl == 0) ? "\"sl\":null," : StringFormat("\"sl\":%.5f,", sl);
      json += (tp == 0) ? "\"tp\":null," : StringFormat("\"tp\":%.5f,", tp);
      json += StringFormat("\"age_seconds\":%I64d", ordAgeSec);
      json += "}";
   }
   json += "],";
   json += "\"open_positions_count\":" + IntegerToString(openCount) + ",";
   json += "\"pending_orders_count\":" + IntegerToString(pendingCount);
   json += "}";
   return json;
}

bool SelectPositionByTicket(const ulong ticket) {

   if(PositionSelectByTicket(ticket)) {
      return true;
   }

   int total = PositionsTotal();
   int i;

   for(i = 0; i < total; i++) {
      if(PositionGetSymbol(i) != "") {
         ulong posTicket = PositionGetInteger(POSITION_TICKET);
         int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
         string posComment = PositionGetString(POSITION_COMMENT);

         if(posMagic == (int)ticket) {
            RegisterTicketMap(posTicket, ticket);
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }

         if(posComment == IntegerToString(ticket)) {
            RegisterTicketMap(posTicket, ticket);
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }
      }
   }

   for(i = 0; i < total; i++) {
      if(PositionGetSymbol(i) != "") {
         ulong posTicket = PositionGetInteger(POSITION_TICKET);

         ulong mappedOriginal = GetOriginalTicket(posTicket);
         if(mappedOriginal == ticket && mappedOriginal != posTicket) {
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }

         if(posTicket == ticket) {
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }
      }
   }

   for(i = 0; i < total; i++) {
      if(PositionGetSymbol(i) != "") {
         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, "from #" + IntegerToString(ticket)) >= 0) {
            ulong posTicket = PositionGetInteger(POSITION_TICKET);
            RegisterTicketMap(posTicket, ticket);
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }
      }
   }

   return false;
}

bool SelectPositionByMagicAndComment(const int magic, const string masterOrderId) {
   if(magic == 0 && masterOrderId == "") {
      return false;
   }

   int total = PositionsTotal();

   for(int i = 0; i < total; i++) {
      if(PositionGetSymbol(i) != "") {
         bool magicMatch = (magic == 0) || ((int)PositionGetInteger(POSITION_MAGIC) == magic);
         bool commentMatch = (masterOrderId == "") || (PositionGetString(POSITION_COMMENT) == masterOrderId);

         if(magicMatch && commentMatch) {
            ulong posTicket = PositionGetInteger(POSITION_TICKET);
            if(PositionSelectByTicket(posTicket)) {
               return true;
            }
         }
      }
   }

   return false;
}

bool SelectOrderByTicket(const ulong ticket) {
   if(ticket == 0) return false;

   if(OrderSelect(ticket)) {
      return true;
   }

   int total = OrdersTotal();

   for(int i = 0; i < total; i++) {
      ulong orderTicket = OrderGetTicket(i);
      if(orderTicket > 0) {
         int orderMagic = (int)OrderGetInteger(ORDER_MAGIC);
         string orderComment = OrderGetString(ORDER_COMMENT);

         if(orderMagic == (int)ticket) {
            if(OrderSelect(orderTicket)) {
               return true;
            }
         }

         if(orderComment == IntegerToString(ticket)) {
            if(OrderSelect(orderTicket)) {
               return true;
            }
         }
      }
   }

   return false;
}

string PendingTypeString(const ENUM_ORDER_TYPE type) {
   if(type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT) return "limit";
   if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP) return "stop";
   return "pending";
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
   long secs = (long)sec + (long)min * 60L + (long)hour * 3600L;
   secs += (long)doy * 86400L;
   secs += (long)(tm_year - 70) * 31536000L;
   secs += (long)((tm_year - 69) / 4) * 86400L;
   secs -= (long)((tm_year - 1) / 100) * 86400L;
   secs += (long)((tm_year + 299) / 400) * 86400L;
   return (long)secs;
}

#define UNIX_EPOCH_2000_SEC 946684800
long DealTimeToUnixUtc(const datetime dealTime) {
   if(dealTime > 0 && dealTime < 1000000000)
      return (long)dealTime + UNIX_EPOCH_2000_SEC;
   return ToUnixUtc(dealTime);
}

long GetCurrentUnixUtc() {
   return ToUnixUtc(TimeCurrent());
}

bool ArrayContainsU(const ulong &arr[], const ulong value) {
   int total = ArraySize(arr);
   int i;
   for(i = 0; i < total; i++) {
      if(arr[i] == value) return true;
   }
   return false;
}

void ArrayPushU(ulong &arr[], const ulong value) {
   int size = ArraySize(arr);
   ArrayResize(arr, size + 1);
   arr[size] = value;
}
