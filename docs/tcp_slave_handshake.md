# Handshake TCP: slave → master (dentro de este repo)

Cuando un **slave** (copybridge en cuenta MT slave) se conecta al **master** (copybridge en cuenta MT master), ambos usan este protocolo. Todo está en este repositorio.

## Master (TcpServer)

- Acepta la conexión TCP y en `receive_connection_account_id`:
  1. Lee la primera **línea** (hasta `\n`).
  2. Extrae `account_id` o `accountId` del JSON (es el login del slave).
  3. Responde **una línea** terminada en `\n`:
     ```json
     {"status":"ready","account_id":"<mismo_account_id>"}
     ```
  4. Si `send()` no envía todos los bytes, devuelve error (cliente no queda “conectado” para nosotros).

## Slave (TcpClient)

- En `send_connection_account_id`:
  1. Envía **una línea** terminada en `\n`:
     ```json
     {"account_id":"<slave_login>"}
     ```
  2. Lee la respuesta del master **hasta** `\n` (varios `recv` si hace falta).
  3. Considera la conexión OK si la respuesta contiene `"status":"ready"` (con o sin espacio después de `:`).

## Resumen

| Lado   | Envía                                      | Espera / Responde                         |
|--------|--------------------------------------------|-------------------------------------------|
| Slave  | `{"account_id":"12345678"}\n`              | Una línea que contenga `"status":"ready"` |
| Master | Lee esa línea, extrae `account_id`         | `{"status":"ready","account_id":"12345678"}\n` |

Para que el slave funcione, su `master_tcp_url` debe apuntar al **puerto TCP del copybridge del master** (el que expone el heartbeat del master), no a otro servicio.

El slave acepta también `"status":"connected"` en la respuesta del handshake (p. ej. servidor en 7776).

---

## Formato de eventos en el wire (master → slave)

**Un evento = una línea terminada en `\n`.** Ese es el único delimitador: cuando vemos `\n` consideramos la línea completa y la pasamos al bot. El master envía una línea por evento (BridgeServer::simplify_event_json + `"\n"`). Si no hay `\n`, el slave acumula y espera más datos.

| event          | Campos típicos (raíz) | Acción slave |
|----------------|------------------------|--------------|
| `placed`       | ticket, symbol, type, side, volume, price, sl, tp, ... | create |
| `modified`     | ticket, symbol, sl, tp, volume, ... (incl. cambios por cierre parcial o agregar lotes) | modify |
| `closed`       | ticket | cancel |
| (snapshot)     | open_positions, pending_orders (arrays) | reconcile_snapshot |
