#!/usr/bin/env python3
import argparse
import base64
import hashlib
import hmac
import json
from pathlib import Path


Q = 2**255 - 19
L = 2**252 + 27742317777372353535851937790883648493


def inverse(value):
    return pow(value, Q - 2, Q)


D = (-121665 * inverse(121666)) % Q
I = pow(2, (Q - 1) // 4, Q)


def xrecover(y):
    xx = (y * y - 1) * inverse(D * y * y + 1)
    x = pow(xx % Q, (Q + 3) // 8, Q)
    if (x * x - xx) % Q:
        x = (x * I) % Q
    return Q - x if x & 1 else x


BY = (4 * inverse(5)) % Q
B = (xrecover(BY), BY)
IDENTITY = (0, 1)


def point_add(left, right):
    x1, y1 = left
    x2, y2 = right
    product = D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * inverse(1 + product)
    y3 = (y1 * y2 + x1 * x2) * inverse(1 - product)
    return x3 % Q, y3 % Q


def scalar_mult(point, scalar):
    result = IDENTITY
    addend = point
    while scalar:
        if scalar & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        scalar >>= 1
    return result


def encode_point(point):
    x, y = point
    return (y | ((x & 1) << 255)).to_bytes(32, "little")


def decode_point(encoded):
    if len(encoded) != 32:
        raise ValueError("invalid Ed25519 public point")
    value = int.from_bytes(encoded, "little")
    y = value & ((1 << 255) - 1)
    if y >= Q:
        raise ValueError("invalid Ed25519 point encoding")
    x = xrecover(y)
    if (x & 1) != (value >> 255):
        x = Q - x
    point = (x, y)
    if (-x * x + y * y - 1 - D * x * x * y * y) % Q:
        raise ValueError("Ed25519 point is not on curve")
    return point


def decode_base64url(value):
    text = str(value or "").strip()
    return base64.urlsafe_b64decode(text + "=" * ((4 - len(text) % 4) % 4))


def verify_signature(public_key, message, signature):
    if len(public_key) != 32 or len(signature) != 64:
        return False
    encoded_r = signature[:32]
    scalar_s = int.from_bytes(signature[32:], "little")
    if scalar_s >= L:
        return False
    try:
        point_a = decode_point(public_key)
        point_r = decode_point(encoded_r)
    except ValueError:
        return False
    challenge = int.from_bytes(
        hashlib.sha512(encoded_r + public_key + message).digest(), "little"
    ) % L
    left = encode_point(scalar_mult(B, scalar_s))
    right = encode_point(point_add(point_r, scalar_mult(point_a, challenge)))
    return hmac.compare_digest(left, right)


def verify_files(manifest, release_dir):
    failures = []
    for name, expected in manifest.get("sha256", {}).items():
        path = release_dir / name
        if not path.is_file():
            failures.append(f"missing: {name}")
            continue
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if not hmac.compare_digest(actual, str(expected).lower()):
            failures.append(f"checksum mismatch: {name}")
    return failures


def main():
    parser = argparse.ArgumentParser(description="Verify an t聊 Ed25519 release manifest.")
    parser.add_argument("--public-key", required=True, help="Raw Ed25519 public key in base64url form.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--release-dir")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    message = manifest_path.read_bytes()
    signature = decode_base64url(Path(args.signature).read_text(encoding="ascii"))
    public_key = decode_base64url(args.public_key)
    if not verify_signature(public_key, message, signature):
        raise SystemExit("t聊 release manifest signature is invalid.")
    manifest = json.loads(message.decode("utf-8"))
    if args.release_dir:
        failures = verify_files(manifest, Path(args.release_dir))
        if failures:
            raise SystemExit("\n".join(failures))
    print(f"t聊 release verified: {manifest.get('release', 'unknown')}")


if __name__ == "__main__":
    main()
