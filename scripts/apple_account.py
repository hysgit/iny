"""Use an existing local App Store Connect key; never saves or prints the key/JWT."""
import argparse
import base64
import json
from pathlib import Path
import time
import urllib.request
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec, utils
from cryptography.hazmat.primitives.serialization import load_pem_private_key


class AppleAccount:
    def __init__(self, issuer, key_id, key_file):
        self.issuer = issuer
        self.key_id = key_id
        self.key = load_pem_private_key(Path(key_file).read_bytes(), password=None)

    def request(self, path, method="GET", payload=None):
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(",", ":")).encode()).decode().rstrip("=")
        now = int(time.time())
        message = encode({"alg": "ES256", "kid": self.key_id, "typ": "JWT"}) + "." + encode({"iss": self.issuer, "iat": now - 30, "exp": now + 600, "aud": "appstoreconnect-v1"})
        signature = self.key.sign(message.encode(), ec.ECDSA(hashes.SHA256()))
        r, s = utils.decode_dss_signature(signature)
        token = message + "." + base64.urlsafe_b64encode(r.to_bytes(32, "big") + s.to_bytes(32, "big")).decode().rstrip("=")
        request = urllib.request.Request("https://api.appstoreconnect.apple.com" + path,
            data=json.dumps(payload).encode() if payload else None, method=method,
            headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def ensure_bundle(self):
        result = self.request("/v1/bundleIds?filter[identifier]=net.icycloud.iny")["data"]
        if result:
            return result[0]
        return self.request("/v1/bundleIds", "POST", {"data": {"type": "bundleIds", "attributes": {"identifier": "net.icycloud.iny", "name": "Iny", "platform": "IOS"}}})["data"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--key-file", required=True)
    parser.add_argument("action", choices=["check", "ensure-bundle"])
    args = parser.parse_args()
    client = AppleAccount(args.issuer, args.key_id, args.key_file)
    if args.action == "ensure-bundle":
        result = client.ensure_bundle()
        output = {"id": result["id"], "identifier": result["attributes"]["identifier"], "name": result["attributes"]["name"]}
    else:
        result = client.request("/v1/apps?filter[bundleId]=net.icycloud.iny")["data"]
        output = {"inyAppRecords": [{"id": app["id"], "name": app["attributes"]["name"]} for app in result]}
    print(json.dumps(output, ensure_ascii=False, indent=2))
