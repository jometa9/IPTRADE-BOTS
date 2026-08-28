# Unified Events API Documentation

## 0. Heartbeat (Bot → API)

The copybridge DLL sends a periodic POST to the webhook configured in the EA (input "External server URL"). **One EA = one account**; the body is a single object at the root, with no `accounts` or wrappers.

**Method:** `POST` to the webhook URL (e.g. `https://your-api.com/api/heartbeat`)

**Content-Type:** `application/json`

**Body (schema that iptrade-api must accept):**

```json
{
  "api_url": "http://localhost:40000/api/accounts/12345678",
  "account_id": "12345678",
  "platform": "metatrader4",
  "server": "Example-Broker",
  "tcp_url": null
}
```

| Field        | Type    | Description |
|--------------|---------|-------------|
| `api_url`    | string  | Bridge base URL + `/api/accounts/{account_id}` |
| `account_id` | string  | Account login |
| `platform`   | string  | `"metatrader4"` or `"metatrader5"` |
| `server`     | string  | Broker server |
| `tcp_url`    | string \| null | TCP URL when account is master; `null` for slave/pending |

**Important:** The API (iptrade-api) must deserialize this body with a struct that has these fields. `trader_login`, `is_live` and `account_name` are no longer sent. If the struct has `api_type`, `public_ip`, `accounts`, `capacity`, those fields are not sent and will remain null; update the heartbeat struct to the fields above.

---

## 1. OUTGOING Events (Bot → External Server)

### 1.1 Event `ready`

```json
{
  "event": "ready",
  "server_url": "http://127.0.0.1:40123",
  "account_id": 123456,
  "platform": "metatrader4|metatrader5"
}
```

### 1.2 Event `placed`

```json
{
  "event": "placed",
  "timestamp": 1704456789,
  "ticket": 1234567,
  "symbol": "EURUSD",
  "type": "market|limit|stop",
  "side": "buy|sell",
  "volume": 0.10,
  "price": 1.08450,
  "sl": 1.08200,
  "tp": 1.09000
}
```

### 1.3 Event `modified`

```json
{
  "event": "modified",
  "timestamp": 1704456789,
  "ticket": 1234567,
  "sl": 1.08300,
  "tp": 1.09100,
  "price": 1.08480
}
```

### 1.4 Event `closed`

This event unifies the previous `closed` and `deleted` events.

```json
{
  "event": "closed",
  "timestamp": 1704456789,
  "ticket": 1234567
}
```

### 1.5 Event `partial_close`

When a position is partially closed.

```json
{
  "event": "partial_close",
  "timestamp": 1704456789,
  "ticket": 1234567,
  "closed_volume": 0.05,
  "sl": 1.08200,
  "tp": 1.09000
}
```
## 2. INCOMING Commands (Client → Bot)

These are the commands the bot receives via HTTP POST on its local server.

### 2.1 Command `create`

MT4 OK
**Endpoint:** `POST /orders`

**Request:**
The request body contains the payload directly (no `action`/`command_id` wrapper). The DLL adds these fields internally.

```json
{
  "ticket": 1234567,
  "symbol": "EURUSD",
  "type": "market|limit|stop",
  "side": "buy|sell",
  "volume": 0.10,
  "price": 1.08450,
  "sl": 1.08200,
  "tp": 1.09000
}
```

**Note:** The `price` parameter can always be sent. The code handles its use internally by order type:
- **market**: `price` is ignored (current market price is used)
- **limit**: `price` is the limit order price
- **stop**: `price` is the stop order trigger price

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "ticket": 1234567,
    "status": "placed",
    "executed_price": 1.08452,
    "executed_volume": 0.10
  }
}
```

### 2.2 Command `modify`
MT4 MARKET OK
MT4 LIMIT OK

**Endpoint:** `POST /orders/modify`

**Request:**
The request body contains the payload directly (no `action`/`command_id` wrapper).

```json
{
  "ticket": 1234567,
  "sl": 1.08300,
  "tp": 1.09100,
  "price": 1.08480,
  "volume": 0.12
}
```

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "ticket": 1234567,
    "status": "modified"
  }
}
```

### 2.3 Command `cancel`

**Endpoint:** `POST /orders/cancel`

**Request:**
The request body contains the payload directly (no `action`/`command_id` wrapper).

```json
{
  "ticket": 1234567,
  "close_volume": 0.05
}
```

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "ticket": 1234567,
    "status": "closed|partial_closed|cancelled",
    "closed_volume": 0.05,
    "remaining_volume": 0.05,
    "new_ticket": 1234568
  }
}
```

### 2.4 Command `account`

**Endpoint:** `POST /account` (para comandos) o `GET /account/*` (para queries)

**Request:**
```json
{
  "action": "account",
  "command_id": 123456789,
  "payload": {}
}
```

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "status": "updated"
  }
}
```

## 3. REST Query Endpoints

### 3.1 GET `/account/info`
MT4 OK

Returns account information.

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "account": {
      "login": 123456,
      "name": "Demo Account",
      "platform": "metatrader4|metatrader5",
      "currency": "USD",
      "balance": 10000.00,
      "equity": 10050.00,
      "margin": 100.00,
      "free_margin": 9950.00,
      "margin_level": 10050.00,
      "leverage": 100
    }
  }
}
```

### 3.2 GET `/account/orders-positions`
MT4 OK

Returns open positions and pending orders.

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "open_positions": [
      {
        "ticket": 1234567,
        "symbol": "EURUSD",
        "type": "market",
        "side": "buy",
        "volume": 0.10,
        "open_price": 1.08450,
        "current_price": 1.08550,
        "sl": 1.08200,
        "tp": 1.09000,
        "profit": 100.00,
        "swap": -0.50,
        "commission": -2.00,
        "open_time": 1704450000,
        "magic": 123456,
        "comment": "MASTER-ABC123"
      }
    ],
    "pending_orders": [
      {
        "ticket": 1234568,
        "symbol": "GBPUSD",
        "type": "limit",
        "side": "sell",
        "volume": 0.20,
        "price": 1.27000,
        "sl": 1.27500,
        "tp": 1.26000,
        "expire": 1704500000,
        "magic": 123457,
        "comment": "MASTER-XYZ789"
      }
    ]
  }
}
```

### 3.3 GET `/account/history`
MT4 OK

Returns closed trade history.

**Query Parameters:**
- `days`: number of days back (default: 30)
- `limit`: maximum records (default: 1000)

**Request example:**
```bash
curl -X GET "http://localhost:40123/account/history"
```

**Response:**
```json
{
  "success": true,
  "error": null,
  "data": {
    "history": [
      {
        "ticket": 1234560,
        "symbol": "EURUSD",
        "type": "market",
        "side": "buy",
        "volume": 0.10,
        "open_price": 1.08000,
        "close_price": 1.08100,
        "open_time": 1704400000,
        "close_time": 1704450000,
        "profit": 100.00,
        "swap": -0.50,
        "commission": -2.00,
        "magic": 123450,
        "comment": "tp"
      }
    ]
  }
}
```

## 4. Error Handling

All responses follow the same format. On error:

```json
{
  "success": false,
  "error": {
    "code": "SYMBOL_NOT_FOUND|INVALID_VOLUME|INSUFFICIENT_MARGIN|etc",
    "message": "Detailed error description",
    "details": {
      "field": "volume",
      "value": -0.01,
      "min": 0.01
    }
  },
  "data": null
}
```

### Standard Error Codes

| Code | Description | HTTP Status |
|--------|-------------|-------------|
| `INVALID_REQUEST` | Invalid request format | 400 |
| `SYMBOL_NOT_FOUND` | Symbol not available | 404 |
| `INVALID_VOLUME` | Volume out of range | 400 |
| `INSUFFICIENT_MARGIN` | Insufficient margin | 400 |
| `INVALID_PRICE` | Invalid price for order type | 400 |
| `ORDER_NOT_FOUND` | Ticket not found | 404 |
| `MODIFICATION_FAILED` | Modification failed | 400 |
| `CLOSE_FAILED` | Close failed | 400 |
| `BROKER_ERROR` | Broker error | 500 |
| `TIMEOUT` | Operation timeout | 408 |

## 5. Security

The server listens on localhost only. Mutating bridge endpoints (POST/PUT) require the shared local `x-api-key` / `x-api-secret` headers (see `src/ApiAuth.cpp` and `check_api_auth` in `src/BridgeServer.cpp`); GET endpoints and the WebSocket upgrade do not. Outgoing heartbeats and events include the same headers.
