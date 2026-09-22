#!/usr/bin/env python3
# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#
# SRP-6a as Luanti does it, written separately from src/impl/srp.cpp so that
# the two can be compared. Prints the vectors that srp.cpp's self-test holds.
import hashlib

N_hex = (
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC319294"
    "3DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310D"
    "CD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FB"
    "D5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF74"
    "7359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A"
    "436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D"
    "5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E73"
    "03CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6"
    "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F"
    "9E4AFF73")
N = int(N_hex, 16)
g = 2

def H(b):
    return hashlib.sha256(b).digest()

def to_bytes(n):
    if n == 0:
        return b""
    return n.to_bytes((n.bit_length() + 7) // 8, "big")

def pad(n):
    return to_bytes(n).rjust(len(to_bytes(N)), b"\0")

def H_nn(n1, n2):
    return int.from_bytes(H(pad(n1) + pad(n2)), "big")

def calculate_x(salt, username_for_verifier, password):
    inner = H(username_for_verifier.encode() + b":" + password.encode())
    return int.from_bytes(H(salt + inner), "big")

def verifier(salt, username_for_verifier, password):
    return pow(g, calculate_x(salt, username_for_verifier, password), N)

def calculate_M(username, salt, A, B, K):
    H_N = H(to_bytes(N))
    H_g = H(to_bytes(g))
    H_xor = bytes(a ^ b for a, b in zip(H_N, H_g))
    return H(H_xor + H(username.encode()) + salt + to_bytes(A) + to_bytes(B) + K)

def main():
    for data in [b"", b"abc", b"a" * 56, b"x" * 1000]:
        name = repr(data) if len(data) < 20 else "%s * %d" % (repr(data[:1]), len(data))
        print("sha256(%s) = %s" % (name, hashlib.sha256(data).hexdigest()))

    username = "TestPlayer"
    username_for_verifier = username.lower()
    password = "hunter2"
    salt = bytes(range(16))
    a = int.from_bytes(bytes((i * 7 + 1) & 0xff for i in range(32)), "big")
    b = int.from_bytes(bytes((i * 13 + 5) & 0xff for i in range(32)), "big")

    v = verifier(salt, username_for_verifier, password)
    k = H_nn(N, g)
    A = pow(g, a, N)
    B = (k * v + pow(g, b, N)) % N
    u = H_nn(A, B)
    x = calculate_x(salt, username_for_verifier, password)
    S_client = pow((B - k * pow(g, x, N)) % N, a + u * x, N)
    S_server = pow(A * pow(v, u, N), b, N)
    assert S_client == S_server
    K = H(to_bytes(S_client))
    M = calculate_M(username, salt, A, B, K)
    H_AMK = H(to_bytes(A) + M + K)

    print()
    print("username           = %s" % username)
    print("password           = %s" % password)
    print("salt               = %s" % salt.hex())
    print("a                  = %s" % to_bytes(a).hex())
    print("verifier           = %s" % to_bytes(v).hex())
    print("A                  = %s" % to_bytes(A).hex())
    print("B                  = %s" % to_bytes(B).hex())
    print("M                  = %s" % M.hex())
    print("H_AMK              = %s" % H_AMK.hex())

main()
