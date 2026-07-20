#!/usr/bin/env node
import fs from "node:fs";
import process from "node:process";
import {createPublicKey, verify} from "node:crypto";


function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : "";
}

function decodeBase64url(value) {
  return Buffer.from(String(value || "").replace(/-/g, "+").replace(/_/g, "/"), "base64");
}

const publicKeyText = argument("--public-key");
const manifestPath = argument("--manifest");
const signaturePath = argument("--signature");
if (!publicKeyText || !manifestPath || !signaturePath) {
  console.error("Usage: verify-release.mjs --public-key KEY --manifest FILE --signature FILE");
  process.exit(2);
}

const message = fs.readFileSync(manifestPath);
const signature = decodeBase64url(fs.readFileSync(signaturePath, "utf8").trim());
const key = createPublicKey({
  key: {
    kty: "OKP",
    crv: "Ed25519",
    x: publicKeyText,
  },
  format: "jwk",
});
if (!verify(null, message, key, signature)) {
  console.error("t聊 release manifest signature is invalid.");
  process.exit(1);
}
const manifest = JSON.parse(message.toString("utf8"));
console.log(`t聊 release verified: ${manifest.release || "unknown"}`);
