# Unified SMS API Client Integration Guide

## Purpose

This document defines one client contract for both SMS server implementations.
The SMS request, job model, polling behavior, status values, validation rules,
and delivery semantics are shared. Only the server address and access-control
behavior differ.

## Server Address and Authentication

The client must read the complete server origin from the
`LOCAL_DEVICE_ADDRESS` environment variable. The value includes the scheme,
host, and port, and must not include `/api/sms`:

```dotenv
# Server 1 example
LOCAL_DEVICE_ADDRESS=http://192.168.2.1:8091

# Server 2 example
LOCAL_DEVICE_ADDRESS=http://192.168.2.1:8080
```

Deployment configuration selects the correct address and port. Application
code must not hard-code a port or attempt to discover the server by sending an
SMS.

The client must send the configured `device-token` header with every `POST`
and `GET` request to both server implementations. Server 1 validates the
token. Server 2 does not use the token and ignores the header, so sending it is
safe and keeps the client behavior identical.

Do not include the token in URLs, logs, analytics, crash reports, or error
messages.

## Common Wire Contract

Both servers expose these endpoints:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/api/sms` | Create and queue one SMS job |
| `GET` | `/api/sms/{id}` | Read the current job status |

All request and response bodies are UTF-8 JSON. API errors have this shape:

```json
{
  "error": "error-code"
}
```

## Request Headers

The client always builds request headers with `device-token`:

```typescript
function accessHeaders(deviceToken: string): Record<string, string> {
  return { "device-token": deviceToken };
}
```

For `POST /api/sms`, also send:

```http
Content-Type: application/json
```

## Create an SMS Job

### Request

```http
POST /api/sms
Content-Type: application/json
device-token: <configured-device-token>
```

```json
{
  "to": "+989121234567",
  "message": "سلام"
}
```

### Request fields

| Field | Type | Required | Rules |
|---|---|---:|---|
| `to` | string | yes | Optional leading `+`, followed by 3–15 ASCII digits |
| `message` | string | yes | Non-empty, valid UTF-8, one SMS segment |

Spaces, dashes, and parentheses are not allowed in `to`.

### Accepted response

HTTP `202 Accepted`

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "queued"
}
```

The ID is a lowercase UUID. A `202` response only confirms that the job was
stored in the server's in-memory queue. It does not confirm modem acceptance or
recipient delivery.

## Read Job Status

### Request

```http
GET /api/sms/ee20e864-8896-4fc7-9a0d-2c614d69f14a
device-token: <configured-device-token>
```

### Non-terminal statuses

`queued` means the job is waiting for earlier jobs or for the modem to become
available:

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "queued"
}
```

`sending` means the server is currently submitting the SMS to the modem:

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "sending"
}
```

### Terminal statuses

`sent` means the server received confirmation that the modem accepted the SMS
submission:

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "sent",
  "messageReference": 23
}
```

This definition is independent of whether the server communicates through a
direct modem command channel or through ModemManager/mmcli. It does not mean
that the recipient received the message. Delivery reports are outside this
contract. `messageReference` is a non-negative integer; `0` means that the
modem did not expose a reference.

`failed` means the modem explicitly rejected the submission:

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "failed",
  "error": "modem-rejected"
}
```

`unknown` means submission began, but the final modem response was lost or
timed out:

```json
{
  "id": "ee20e864-8896-4fc7-9a0d-2c614d69f14a",
  "status": "unknown",
  "error": "modem-response-timeout"
}
```

An `unknown` response has one of these errors:

| Error | Meaning |
|---|---|
| `modem-response-timeout` | No final modem result was received before the submission timeout |
| `modem-connection-lost` | The server lost its modem connection after submission began |

Never automatically resubmit an `unknown` job. The original SMS may have been
accepted, and resubmission can produce a duplicate.

## Shared Validation Rules

For identical behavior with both servers, clients should apply the conservative
common validation rules below. Server validation remains authoritative.

| Message class | Maximum length |
|---|---:|
| GSM 03.38 single-septet characters | 160 Unicode code points |
| UCS2/BMP text, including Persian | 70 Unicode code points |

The 160-character class contains only characters from the GSM 03.38 default
single-septet table, excluding `@` and Escape. Treat `@`, GSM extension-table
characters such as `{`, `}`, `[`, `]`, `^`, `~`, `|`, and `€`, Persian text,
and all other supported BMP characters as UCS2 with the 70-character limit.

Additional rules:

- CR and LF line breaks are supported.
- Emoji and all other non-BMP characters are rejected.
- Surrogates and malformed UTF-8 are rejected.
- C0/C1 controls are rejected, except CR and LF.
- Escape and Ctrl-Z are rejected.
- Empty messages are rejected.
- Multipart/concatenated SMS is not supported.

## Errors

### Common request errors

| HTTP status | Error | Client behavior |
|---:|---|---|
| `400` | `invalid-json` | Correct the JSON body and `Content-Type` |
| `400` | `invalid-phone-number` | Require an optional `+` and 3–15 ASCII digits |
| `400` | `empty-message` | Require message text |
| `400` | `message-too-long` | Shorten the message to one segment |
| `400` | `unsupported-character` | Remove unsupported control or non-BMP characters |
| `405` | `method-not-allowed` | Correct the HTTP method; do not retry unchanged |
| `503` | `sms-queue-full` | Retry later with bounded backoff |

### Access-control errors

The two server implementations expose different wire-level access errors even
though the client sends `device-token` to both:

| Profile | HTTP status | Error | Required action |
|---|---:|---|---|
| Server 1 | `401` | `unauthorized` | Correct the configured device token |
| Server 2 | `403` | `forbidden` | Use a source address present in the server allowlist |

A shared client should normalize both cases to an internal `access-denied`
condition, while retaining the original HTTP status and server error for
diagnostics. Access errors must not be retried until configuration or network
access changes.

### Status lookup errors

| HTTP status | Error | Meaning |
|---:|---|---|
| `404` | `sms-job-not-found` | The ID is invalid, expired, or was lost after a server/device restart |

Queues and status histories are held in memory. A server process, SMS worker,
or device restart may invalidate previous IDs.

## Required Client Workflow

1. Read the base URL from `LOCAL_DEVICE_ADDRESS` and load the device token from
   trusted client configuration.
2. Validate the destination and message using the shared rules.
3. Send exactly one `POST /api/sms` with `device-token`.
4. Store the returned job ID together with the `LOCAL_DEVICE_ADDRESS` value
   that created it.
5. Poll `GET /api/sms/{id}` at the same address, again with `device-token`,
   after one second.
6. Continue polling every 1–2 seconds while status is `queued` or `sending`.
7. Stop on `sent`, `failed`, `unknown`, or `404`.
8. Retry polling after temporary network failures; do not create another job.
9. Never automatically resubmit `unknown` jobs.

A job may remain `queued` indefinitely while the modem is unavailable. A
client-side polling timeout does not authorize creating a replacement job.

If the connection fails before the client receives the response to `POST`, the
result is ambiguous because neither server supports an idempotency key. Do not
silently retry or fail over to the other server; report the uncertainty to the
user.

## TypeScript Types

```typescript
interface SmsClientConfig {
  baseUrl: string;
  deviceToken: string;
}

interface SendSmsRequest {
  to: string;
  message: string;
}

type SmsJobStatus =
  | { id: string; status: "queued" }
  | { id: string; status: "sending" }
  | { id: string; status: "sent"; messageReference: number }
  | { id: string; status: "failed"; error: "modem-rejected" }
  | {
      id: string;
      status: "unknown";
      error: "modem-response-timeout" | "modem-connection-lost";
    };

type SmsServerErrorCode =
  | "invalid-json"
  | "invalid-phone-number"
  | "empty-message"
  | "message-too-long"
  | "unsupported-character"
  | "unauthorized"
  | "forbidden"
  | "sms-queue-full"
  | "sms-job-not-found"
  | "method-not-allowed";

interface SmsServerErrorBody {
  error: SmsServerErrorCode;
}
```

## Unified TypeScript Client

```typescript
class SmsApiError extends Error {
  readonly kind: "access-denied" | "api-error";

  constructor(
    readonly httpStatus: number,
    readonly serverCode: string,
  ) {
    super(serverCode);
    this.name = "SmsApiError";
    this.kind =
      httpStatus === 401 || httpStatus === 403
        ? "access-denied"
        : "api-error";
  }
}

function loadSmsClientConfig(deviceToken: string): SmsClientConfig {
  const address = process.env.LOCAL_DEVICE_ADDRESS?.trim();
  if (!address) {
    throw new Error("LOCAL_DEVICE_ADDRESS is required");
  }
  if (!deviceToken) {
    throw new Error("device-token is required");
  }

  return {
    baseUrl: address.replace(/\/+$/, ""),
    deviceToken,
  };
}

function requestHeaders(
  config: SmsClientConfig,
  includeContentType = false,
): Record<string, string> {
  const headers: Record<string, string> = {
    "device-token": config.deviceToken,
  };
  if (includeContentType) headers["content-type"] = "application/json";
  return headers;
}

async function parseResponse<T>(response: Response): Promise<T> {
  const body = await response.json();
  if (!response.ok) {
    const code =
      typeof body?.error === "string" ? body.error : "unexpected-response";
    throw new SmsApiError(response.status, code);
  }
  return body as T;
}

async function sendSms(
  config: SmsClientConfig,
  input: SendSmsRequest,
): Promise<Extract<SmsJobStatus, { status: "queued" }>> {
  const response = await fetch(`${config.baseUrl}/api/sms`, {
    method: "POST",
    headers: requestHeaders(config, true),
    body: JSON.stringify(input),
  });

  return parseResponse<Extract<SmsJobStatus, { status: "queued" }>>(response);
}

async function getSmsStatus(
  config: SmsClientConfig,
  id: string,
): Promise<SmsJobStatus> {
  const response = await fetch(
    `${config.baseUrl}/api/sms/${encodeURIComponent(id)}`,
    { headers: requestHeaders(config) },
  );

  return parseResponse<SmsJobStatus>(response);
}

async function waitForSms(
  config: SmsClientConfig,
  id: string,
): Promise<SmsJobStatus> {
  for (;;) {
    const job = await getSmsStatus(config, id);
    if (job.status !== "queued" && job.status !== "sending") return job;
    await new Promise((resolve) => setTimeout(resolve, 1_500));
  }
}
```

## cURL Examples

Set the address and port for the target server. The same commands then work for
both implementations:

```bash
export LOCAL_DEVICE_ADDRESS='http://192.168.2.1:8080'

curl -X POST "${LOCAL_DEVICE_ADDRESS}/api/sms" \
  -H 'content-type: application/json' \
  -H 'device-token: <configured-device-token>' \
  --data '{"to":"+989121234567","message":"سلام"}'
```

To poll, use the same environment value and always send the token header:

```bash
curl "${LOCAL_DEVICE_ADDRESS}/api/sms/ee20e864-8896-4fc7-9a0d-2c614d69f14a" \
  -H 'device-token: <configured-device-token>'
```
