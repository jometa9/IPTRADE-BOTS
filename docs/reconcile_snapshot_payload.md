# Reconcile snapshot: cómo llega el payload y cómo se parsea (MT4)

## Flujo de datos

1. **Origen del comando**
   - **TCP (slave conectado al master):** El master envía un evento `snapshot` con `open_positions` y `pending_orders`. La DLL (`SlaveConverter::convert_event_to_command`) convierte ese evento en el comando `reconcile_snapshot` y rellena el `payload`.
   - **HTTP (API/BridgeServer):** El servidor puede enviar un POST con el mismo comando `reconcile_snapshot` y un `payload` construido por la API.

2. **Cómo llega al EA**
   - La DLL expone `PollNextCommand(buffer, len)`. El EA llama a esto en `ProcessIncomingCommands()` y recibe el JSON completo del comando en `buffer`.
   - El EA convierte el buffer a string y extrae:
     - `command_id`: `BridgeJsonGetLong(json, "command_id", 0)`
     - `action`: `BridgeJsonGetString(json, "action", "")` → `"reconcile_snapshot"`
     - `payload`: `BridgeJsonGetObject(json, "payload")` → string del **objeto** interno (no incluye la clave `"payload"`, solo el contenido `{ ... }`).

3. **Formato del objeto `payload`**
   - Es un único objeto JSON con claves en el primer nivel:
     - `open_positions`: array de objetos `[{ "ticket", "symbol", "side", "volume", "sl", "tp", ... }, ...]`
     - `pending_orders`: array de objetos con estructura similar.
     - `lot_multiplier`: número (opcional). Por defecto 1.0.
     - `fixed_lot`: número (opcional). Por defecto 0.0.

## Construcción del payload en la DLL (TCP)

- En `SlaveConverter.cpp`, cuando el evento es `snapshot`:
  - Se extraen `open_positions` y `pending_orders` del evento.
  - Por **cada elemento** de cada array se llama a `convert_command(elem, config)`, que:
    - Convierte `symbol` (traducciones, prefijo/sufijo).
    - Convierte `volume` con `convert_volume(master_volume, config)` (multiplier o fixed_lot según `config.lot_type`).
    - Aplica reverse trading si está configurado.
  - Los volúmenes que llegan al EA en cada posición/pending **ya están en tamaño esclavo**.
  - La DLL añade al payload `"lot_multiplier":1.0,"fixed_lot":0` para indicar que no hay que volver a multiplicar en el EA.

## Parseo en el EA (HandleReconcileSnapshot)

- `open_positions`: `BridgeJsonGetObject(payload, "open_positions")` → string `"[{...},{...}]"`.
- Longitud del array: `BridgeJsonArrayLength(openPositionsArr)`.
- Elemento i-ésimo: `BridgeJsonArrayElement(openPositionsArr, i)` → string `"{...}"`.
- Por cada elemento: `BridgeJsonGetLong(elem, "ticket", 0)`, `BridgeJsonGetString(elem, "symbol", "")`, `BridgeJsonGetDouble(elem, "volume", 0)`, etc.
- Config: `BridgeJsonGetDouble(payload, "lot_multiplier", 1.0)` y `BridgeJsonGetDouble(payload, "fixed_lot", 0.0)`. También se aceptan `lotMultiplier` y `fixedLot` (camelCase).

## Uso de lot_multiplier y fixed_lot en el EA

- **Target de volumen:** Para cada grupo (mismo padre, symbol, side) se agrega el volumen del snapshot y se obtiene `snapVol`. Luego:
  - `targetVol = snapVol * lot_multiplier`
  - Si `fixed_lot > 0`, se redondea `targetVol` a múltiplo de `fixed_lot`.
- Cuando el payload viene de la DLL (TCP), `lot_multiplier` y `fixed_lot` vienen como 1.0 y 0, así que `targetVol = snapVol` (los volúmenes ya venían convertidos).
- Cuando el payload viene por HTTP con volúmenes en tamaño master, el servidor puede enviar `lot_multiplier` y `fixed_lot` reales y el EA aplica la conversión.

## Pendiente → mercado: desfase master/slave

Cuando una orden pendiente se dispara (pasa a posición), master y slave pueden no hacerlo a la vez. El reconcile trata así los dos casos:

| Caso | Comportamiento |
|------|----------------|
| **Master pasa a mercado primero** (slave aún tiene la pendiente) | Snapshot trae el ticket en `open_positions` y ya no en `pending_orders`. FASE 1.1 cancela la pendiente en slave. FASE 2.2 abre la posición con `HandleCreate` tipo market. Queda alineado. |
| **Slave pasa a mercado primero** (master aún tiene la pendiente) | Snapshot trae el ticket en `pending_orders` y aún no en `open_positions`. **No** cerramos la posición en slave (porque su ticket sigue en `pending_orders` → “slave filled first”). **No** creamos otra pendiente si ya existe una posición con ese master ticket. En el siguiente snapshot el master habrá pasado a mercado y ambos quedarán alineados. |

Implementación (MT4 y MT5):

- **FASE 2.1 (cancelar posiciones):** Si la posición no está en `open_positions` pero su master ticket **sí** está en `pending_orders`, no se cancela (slave disparó primero).
- **FASE 1.2 / creación de pendientes:** Antes de crear una pendiente por un ticket del snapshot, se comprueba si ya hay una **posición** con ese master ticket; si existe, no se crea pendiente (evita duplicar y doble exposición).

## Resumen

| Origen   | Volúmenes en payload | lot_multiplier / fixed_lot en payload | En el EA                          |
|----------|----------------------|----------------------------------------|-----------------------------------|
| DLL (TCP)| Ya convertidos       | 1.0 y 0                                | targetVol = snapVol (sin aplicar)  |
| HTTP     | Pueden ser master    | Opcionales (reales o no)               | targetVol = snapVol * multiplier  |
