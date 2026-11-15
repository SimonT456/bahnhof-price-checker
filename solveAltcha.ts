export interface Challenge {
  parameters: {
    algorithm: string;
    cost: number;
    keyLength: number;
    keyPrefix: string;
    nonce: string;
    salt: string;
    expiresAt: number;
    [key: string]: unknown;
  };
  signature: string;
}
function hexBytes(value: string): Uint8Array<ArrayBuffer> {
  // The server sends the nonce and salt as hex; PBKDF2 needs their raw bytes.
  if (!/^(?:[a-f\d]{2})+$/i.test(value)) {
    throw new Error("Invalid ALTCHA hex value");
  }
  return Uint8Array.from(value.match(/../g)!, (byte) => parseInt(byte, 16));
}
export async function solveAltcha(challenge: Challenge): Promise<string> {
  const p = challenge.parameters;
  // Accept supported parameters and bound the work and output size per attempt.
  if (
    p.algorithm !== "PBKDF2/SHA-256" ||
    !Number.isInteger(p.cost) || p.cost < 1 || p.cost > 1000000 ||
    !Number.isInteger(p.keyLength) || p.keyLength < 1 || p.keyLength > 64 ||
    !/^[a-f\d]+$/i.test(p.keyPrefix) || p.keyPrefix.length > p.keyLength * 2 ||
    !Number.isFinite(p.expiresAt) || !challenge.signature
  ) {
    throw new Error("Unsupported or invalid ALTCHA challenge");
  }
  const nonce = hexBytes(p.nonce);
  const salt = hexBytes(p.salt);
  // Each candidate password is the nonce followed by a four-byte counter.
  const password = new Uint8Array(nonce.length + 4);
  password.set(nonce);
  const view = new DataView(password.buffer, nonce.length);
  // Stop at the server's expiry time or after 90 seconds, whichever comes first.
  const deadline = Math.min(Date.now() + 90000, p.expiresAt * 1000);
  for (let counter = 0; counter <= 0xffffffff; counter++) {
    if (Date.now() >= deadline) {
      throw new Error("ALTCHA challenge expired or timed out");
    }
    view.setUint32(0, counter); // Big endian, matching Bahnhof's browser client.
    // Derive a key for this candidate using the server's salt and iteration count.
    const key = await crypto.subtle.importKey(
      "raw",
      password,
      "PBKDF2",
      false,
      ["deriveBits"],
    );
    const bits = await crypto.subtle.deriveBits(
      {
        name: "PBKDF2",
        hash: "SHA-256",
        salt,
        iterations: p.cost,
      },
      key,
      p.keyLength * 8,
    );
    const derivedKey = Array.from(
      new Uint8Array(bits),
      (b) => b.toString(16).padStart(2, "0"),
    ).join("");
    // A solution is any counter whose derived key starts with the required hex prefix.
    if (derivedKey.startsWith(p.keyPrefix.toLowerCase())) {
      // Preserve the signed challenge so the server can verify it alongside the proof.
      const json = JSON.stringify({
        challenge,
        solution: { counter, derivedKey },
      });
      // X-Altcha expects Base64 of the UTF-8 JSON, including any non-ASCII data.
      return btoa(String.fromCharCode(...new TextEncoder().encode(json)));
    }
  }
  throw new Error("ALTCHA challenge has no solution");
}
if (import.meta.main) {
  // Shell interface: read a challenge from stdin and write only its token to stdout.
  try {
    const input = await new Response(Deno.stdin.readable).text();
    console.log(await solveAltcha(JSON.parse(input)));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    Deno.exit(1);
  }
}
