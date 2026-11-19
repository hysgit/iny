"""Provision independent Iny signing and encrypt secrets for hysgit/iny only."""
import argparse
import base64
import ctypes
from ctypes import wintypes
import json
from pathlib import Path
import secrets
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools/python"))
from nacl.public import PublicKey, SealedBox
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import NameOID
from apple_account import AppleAccount
from github_ci import credential


class Blob(ctypes.Structure):
    _fields_ = [("length", wintypes.DWORD), ("data", ctypes.POINTER(ctypes.c_ubyte))]


def protect(data, decrypt=False):
    buffer = ctypes.create_string_buffer(data)
    source = Blob(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte)))
    target = Blob()
    crypt = ctypes.windll.crypt32
    if decrypt:
        result = crypt.CryptUnprotectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    else:
        result = crypt.CryptProtectData(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target))
    if not result:
        raise ctypes.WinError()
    try:
        return ctypes.string_at(target.data, target.length)
    finally:
        free = ctypes.windll.kernel32.LocalFree
        free.argtypes = [ctypes.c_void_p]
        free.restype = ctypes.c_void_p
        free(ctypes.cast(target.data, ctypes.c_void_p))


def setup(args):
    token = credential()
    base = "https://api.github.com/repos/hysgit/iny"

    def github(path, method="GET", payload=None):
        request = urllib.request.Request(base + path, method=method, data=json.dumps(payload).encode() if payload else None,
            headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json", "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read()
        return json.loads(data) if data else None

    public_key = github("/actions/secrets/public-key")
    sealed = SealedBox(PublicKey(base64.b64decode(public_key["key"])))
    account = AppleAccount(args.issuer, args.key_id, args.key_file)
    bundle = account.ensure_bundle()
    folder = ROOT / ".signing"
    folder.mkdir(exist_ok=True)
    metadata_path = folder / "metadata.json"
    if metadata_path.exists():
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        password = protect((folder / "password.dpapi").read_bytes(), decrypt=True).decode()
        p12 = (folder / "Iny.p12").read_bytes()
    else:
        certificates = account.request("/v1/certificates?filter[certificateType]=DISTRIBUTION")["data"]
        if len(certificates) >= 3:
            raise RuntimeError("Distribution certificate limit reached; no existing certificate was revoked")
        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        csr = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Iny Distribution")])).sign(key, hashes.SHA256())
        payload = {"data": {"type": "certificates", "attributes": {"certificateType": "DISTRIBUTION", "csrContent": csr.public_bytes(serialization.Encoding.PEM).decode()}}}
        certificate = account.request("/v1/certificates", "POST", payload)["data"]
        cert = x509.load_der_x509_certificate(base64.b64decode(certificate["attributes"]["certificateContent"]))
        password = secrets.token_urlsafe(32)
        p12 = pkcs12.serialize_key_and_certificates(b"Iny Distribution", key, cert, None, serialization.BestAvailableEncryption(password.encode()))
        (folder / "Iny.p12").write_bytes(p12)
        (folder / "password.dpapi").write_bytes(protect(password.encode()))
        metadata = {"bundleIdentifier": "net.icycloud.iny", "bundleId": bundle["id"], "certificateId": certificate["id"]}
        metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")

    if "profileId" not in metadata:
        profile = account.request("/v1/profiles", "POST", {"data": {"type": "profiles",
            "attributes": {"name": "Iny App Store", "profileType": "IOS_APP_STORE"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                "certificates": {"data": [{"type": "certificates", "id": metadata["certificateId"]}]}}}})["data"]
        profile_data = base64.b64decode(profile["attributes"]["profileContent"])
        (folder / "Iny.mobileprovision").write_bytes(profile_data)
        metadata.update(profileId=profile["id"], profileUUID=profile["attributes"]["uuid"])
        metadata_path.write_text(json.dumps(metadata, indent=2), encoding="utf-8")
    profile_data = (folder / "Iny.mobileprovision").read_bytes()
    values = {
        "INY_SIGNING_P12": base64.b64encode(p12).decode(), "INY_SIGNING_PASSWORD": password,
        "INY_PROVISIONING_PROFILE": base64.b64encode(profile_data).decode(),
        "INY_ASC_ISSUER_ID": args.issuer, "INY_ASC_KEY_ID": args.key_id,
        "INY_ASC_PRIVATE_KEY": Path(args.key_file).read_text(encoding="utf-8"),
    }
    for name, value in values.items():
        encrypted = base64.b64encode(sealed.encrypt(value.encode())).decode()
        github("/actions/secrets/" + name, "PUT", {"encrypted_value": encrypted, "key_id": public_key["key_id"]})
        print("Configured encrypted secret: " + name, flush=True)
    print(json.dumps(metadata, indent=2), flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--key-file", required=True)
    setup(parser.parse_args())
