/* eslint-disable no-console */
const accountId = process.env.ACCOUNT_ID || "123456";
const bridgePort = process.env.BRIDGE_PORT || "40000";
const apiKey = process.env.API_KEY || "";
const apiSecret = process.env.API_SECRET || "";

const endpoint = process.env.WS_URL || `ws://127.0.0.1:${bridgePort}/api/accounts/${accountId}/orders`;

const WSClient = require("ws");

const headers = {};
if (apiKey) headers["x-api-key"] = apiKey;
if (apiSecret) headers["x-api-secret"] = apiSecret;

console.log(`Connecting to ${endpoint}`);
const ws = new WSClient(endpoint, { headers });

ws.onopen = () => {
  console.log("WS connected");
};

ws.onmessage = (event) => {
  const raw = typeof event.data === "string" ? event.data : String(event.data);
  try {
    const payload = JSON.parse(raw);
    console.log("orders:", payload);
  } catch (err) {
    console.log("raw:", raw);
  }
};

ws.onerror = (err) => {
  console.error("WS error:", err.message || err);
};

ws.onclose = (event) => {
  console.log(`WS closed code=${event.code} reason=${event.reason || ""}`);
};
