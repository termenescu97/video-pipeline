# Romanian Bank APIs — Comprehensive Documentation

> **Last updated:** February 2026
> **Sources:** Bank developer portals, BNR regulations, Finqware API quality reports, Open Banking Tracker, BankIO Romanian ASPSPs registry

---

## Table of Contents

1. [Overview & Regulatory Landscape](#1-overview--regulatory-landscape)
2. [Authentication (Common Pattern)](#2-authentication-common-pattern)
3. [Tier 1 Banks (Mature APIs, Beyond PSD2)](#3-tier-1-banks-mature-apis-beyond-psd2)
4. [Tier 2 Banks (Standard PSD2)](#4-tier-2-banks-standard-psd2)
5. [Neobanks & Fintechs](#5-neobanks--fintechs)
6. [Document, Invoice & Statement Capabilities](#6-document-invoice--statement-capabilities)
7. [API Quality Ratings](#7-api-quality-ratings)
8. [Complete Developer Portal Reference](#8-complete-developer-portal-reference)
9. [Payment Infrastructure](#9-payment-infrastructure)

---

## 1. Overview & Regulatory Landscape

### PSD2 in Romania

Romania transposed PSD2 into national law via **Law No. 209/2019** on payment services (effective December 13, 2019). The **National Bank of Romania (BNR)** is the competent authority and issued **BNR Regulation No. 4/2019** to implement PSD2 requirements. All Romanian credit institutions (ASPSPs) are legally required to provide API access to licensed Third Party Providers (TPPs).

### API Standard

Virtually all Romanian banks follow the **Berlin Group NextGenPSD2 Framework** as the API standard. This means:
- RESTful JSON APIs
- OAuth 2.0 for authorization
- eIDAS certificates (QWAC/QSealC) for TPP identification
- Consent-based access model (90-day validity)
- Standardized account information and payment initiation schemas

### Key Statistics

| Metric | Value |
|---|---|
| Registered ASPSPs with APIs | **19** credit institutions + 1 payment institution |
| Total bank APIs available | **52** |
| Monthly API calls (2024) | **~8 million** (via Finqware alone) |
| API error rate (2024) | **0.8%** (down from ~15% in 2022) |
| API availability (2024) | **99.2%** |

### Regulatory Timeline

| Date | Regulation | Impact |
|---|---|---|
| 2019 | **PSD2** (Law 209/2019) | Banks must expose AISP/PISP APIs |
| 2023 | **DORA** (Digital Operational Resilience Act) | Operational resilience requirements |
| 2024 | **BNR bulk payment mandate** | All banks must implement bulk payment APIs |
| Mid-2026 | **PSD3 + PSR** (Payment Services Regulation) | Enhanced open banking, non-bank PSP access |
| ~2027 | **FIDA** (Financial Data Access) | Open Finance — extends to mortgages, savings, investments, pensions, insurance |

### What Romanian Bank APIs Can and Cannot Do

| Capability | Available via API? |
|---|---|
| Account balances | Yes (all banks, AISP) |
| Transaction history | Yes (all banks, AISP) |
| Payment initiation (single) | Yes (all banks, PISP) |
| Bulk payments | Yes (mandated by BNR; 4 banks fully automated) |
| Confirmation of funds | Yes (most banks, PIISP) |
| **Invoice upload/download** | **No** — goes through ANAF e-Factura, not banks |
| **Document management** | **No** — proprietary internet banking only |
| **Formatted statements (MT940/CAMT)** | **No** — proprietary internet banking only |
| Direct debit | No — SEPA DD via Transfond SENT, not PSD2 |

---

## 2. Authentication (Common Pattern)

All Romanian banks use a similar authentication pattern based on the Berlin Group NextGenPSD2 specification.

### Prerequisites

1. **TPP License** — You need an AISP and/or PISP license from your national authority (or passported from another EU country)
2. **eIDAS Certificates** — Qualified Website Authentication Certificate (QWAC) for TLS and Qualified Seal Certificate (QSealC) for request signing
3. **Registration** — Register on the bank's developer portal to get API credentials

### Typical OAuth 2.0 Flow

#### Step 1: Create Consent

```bash
curl -X POST https://{bank-api}/v1/consents \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: $(uuidgen)" \
  -H "TPP-Redirect-URI: https://your-app.com/callback" \
  --cert tpp-qwac.pem \
  --key tpp-qwac-key.pem \
  -d '{
    "access": {
      "accounts": [{"iban": "RO49AAAA1B31007593840000"}],
      "balances": [{"iban": "RO49AAAA1B31007593840000"}],
      "transactions": [{"iban": "RO49AAAA1B31007593840000"}]
    },
    "recurringIndicator": true,
    "validUntil": "2026-05-24",
    "frequencyPerDay": 4,
    "combinedServiceIndicator": false
  }'
```

**Response:**
```json
{
  "consentStatus": "received",
  "consentId": "consent-12345",
  "_links": {
    "scaRedirect": {
      "href": "https://{bank}/authorize?consentId=consent-12345"
    },
    "status": {
      "href": "/v1/consents/consent-12345/status"
    }
  }
}
```

#### Step 2: User Authorization (SCA)

Redirect the user to the `scaRedirect` URL. The user authenticates via their bank's app or web interface. Two SCA methods exist:

| Method | Description | Banks Using It |
|---|---|---|
| **Redirect** | User redirected to bank's web/app login | BT, BCR, ING, Raiffeisen, UniCredit, most others |
| **Decoupled** | User approves in their mobile banking app separately | BRD (exclusively), some others as secondary |

After SCA, the bank redirects back to your `TPP-Redirect-URI` with the consent confirmed.

#### Step 3: Get Access Token

```bash
curl -X POST https://{bank-api}/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --cert tpp-qwac.pem \
  --key tpp-qwac-key.pem \
  -d "grant_type=authorization_code" \
  -d "code={authorization_code}" \
  -d "client_id={client_id}" \
  -d "redirect_uri=https://your-app.com/callback"
```

#### Step 4: Access Account Data

```bash
# List accounts
curl https://{bank-api}/v1/accounts \
  -H "Authorization: Bearer {access_token}" \
  -H "Consent-ID: consent-12345" \
  -H "X-Request-ID: $(uuidgen)" \
  --cert tpp-qwac.pem \
  --key tpp-qwac-key.pem
```

**Response:**
```json
{
  "accounts": [
    {
      "resourceId": "acc-001",
      "iban": "RO49AAAA1B31007593840000",
      "currency": "RON",
      "name": "Current Account",
      "cashAccountType": "CACC",
      "status": "enabled",
      "_links": {
        "balances": {"href": "/v1/accounts/acc-001/balances"},
        "transactions": {"href": "/v1/accounts/acc-001/transactions"}
      }
    }
  ]
}
```

### Consent Validity

- **Maximum duration:** 90 days
- **Frequency:** Typically 4 requests per day per account (configurable per consent)
- **Renewal:** New consent + SCA required after expiry

---

## 3. Tier 1 Banks (Mature APIs, Beyond PSD2)

These banks have mature developer portals, good documentation, and/or extended API offerings beyond PSD2 minimum.

---

### 3.1 Banca Transilvania (BT)

**Romania's largest bank. Reliable APIs with excellent support.**

| | |
|---|---|
| **Developer Portal** | https://apistorebt.ro/bt/sb/ |
| **Developer Support** | https://en.bancatransilvania.ro/developer-support |
| **API Standard** | Berlin Group NextGenPSD2 |
| **Auth** | OAuth 2.0 with PKCE; eIDAS QWAC/QSealC |
| **SCA** | Web redirect + BT Pay mobile app deeplink |
| **Sandbox** | Yes — test data at apistorebt.ro |

**API Products:**

| API | Type | Description |
|---|---|---|
| Account Information (AISP) | PSD2 | List accounts, balances, transaction history |
| Payment Initiation (PISP) | PSD2 | Single payments (RON and EUR), bulk payments |
| Confirmation of Funds (PIISP) | PSD2 | Fund availability check |

**Notable:**
- BT Go app has **direct ANAF e-Factura integration** — the only Romanian bank confirmed to have this. Users can log into SPV, auto-generate and submit e-invoices to ANAF.
- Parent company of Salt Bank (neobank)
- BT Ultra credentials are NOT supported via API

**List accounts:**
```bash
curl https://apistorebt.ro/bt/sb/v1/accounts \
  -H "Authorization: Bearer {access_token}" \
  -H "Consent-ID: {consent_id}" \
  -H "X-Request-ID: $(uuidgen)" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem
```

**Get transactions:**
```bash
curl "https://apistorebt.ro/bt/sb/v1/accounts/{accountId}/transactions?dateFrom=2025-01-01&dateTo=2025-01-31&bookingStatus=booked" \
  -H "Authorization: Bearer {access_token}" \
  -H "Consent-ID: {consent_id}" \
  -H "X-Request-ID: $(uuidgen)" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem
```

**Initiate payment:**
```bash
curl -X POST https://apistorebt.ro/bt/sb/v1/payments/sepa-credit-transfers \
  -H "Authorization: Bearer {access_token}" \
  -H "Content-Type: application/json" \
  -H "X-Request-ID: $(uuidgen)" \
  -H "TPP-Redirect-URI: https://your-app.com/callback" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem \
  -d '{
    "instructedAmount": {"currency": "RON", "amount": "1500.00"},
    "debtorAccount": {"iban": "RO49BTRL0301207593840000"},
    "creditorName": "Supplier SRL",
    "creditorAccount": {"iban": "RO15RZBR0000060019330955"},
    "remittanceInformationUnstructured": "Invoice 2025-001"
  }'
```

---

### 3.2 BCR (Banca Comerciala Romana) — Erste Group

**Most extended API offering in Romania. Goes well beyond PSD2.**

| | |
|---|---|
| **Developer Portal** | https://developers.erstegroup.com/docs/guides/bcr-getting-started |
| **Open Banking Page** | https://www.bcr.ro/en/open-banking |
| **API Standard** | NextGenPSD2 (Berlin Group), Erste Group standard |
| **Auth** | OAuth 2.0; eIDAS QWAC |
| **SCA** | Web redirect + George app deeplink |
| **Sandbox** | Yes — Erste Developer Portal with Postman Collections |

**API Products:**

| API | Type | Description |
|---|---|---|
| Accounts API (AISP) | PSD2 | Account list, details, balances, transactions |
| Card Accounts API | PSD2 | Card account list, details, balances, transactions |
| Payments API (PISP) | PSD2 | Single payment initiation, status, content |
| Confirmation of Funds | PSD2 | Fund availability check |
| **Transparent Accounts API** | Beyond PSD2 | Public account data |
| **Places API** | Beyond PSD2 | Branch and ATM locations |
| **Mortgage Calculator API** | Beyond PSD2 | Mortgage simulations |
| **Know Your Customer API** | Beyond PSD2 | KYC data |
| **Exchange Rates API** | Beyond PSD2 | Currency exchange rates |

**Get exchange rates (no auth required):**
```bash
curl https://developers.erstegroup.com/api/bcr/public/v1/exchange-rates
```

**Get account balances:**
```bash
curl https://developers.erstegroup.com/api/bcr/v1/accounts/{accountId}/balances \
  -H "Authorization: Bearer {access_token}" \
  -H "Consent-ID: {consent_id}" \
  -H "X-Request-ID: $(uuidgen)" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem
```

---

### 3.3 BRD — Groupe Societe Generale

**Separate retail and corporate APIs. Decoupled-only SCA.**

| | |
|---|---|
| **Developer Portal** | https://www.devbrd.ro/brd/apicatalog/ |
| **API Standard** | Berlin Group NextGenPSD2 |
| **Auth** | eIDAS certificates |
| **SCA** | Decoupled only — requires BRD Mobile app authorization |
| **Sandbox** | Yes — demo APIs at devbrd.ro |

**API Products:**

| API | Type | Description |
|---|---|---|
| PSD2 Retail API | PSD2 | For MyBRD Net/Mobile and YOU BRD users |
| PSD2 Corporate API | PSD2 | For BRD@ffice users — full corporate treasury |
| Account Information (AIS) | PSD2 | Account details, balances, transactions |
| Payment Initiation (PIS) | PSD2 | Single and bulk payments (RON and EUR) |

**Known Issues:**
- Finqware rated BRD as "extremely unreliable" — frequent unavailability
- Returns data as zip files instead of continuous JSON in some cases
- Some users may not have API access enabled by default
- Decoupled-only SCA can be challenging for automation

---

### 3.4 ING Bank Romania

**Global ING portal. Premium APIs beyond PSD2. Open-source SDK.**

| | |
|---|---|
| **Developer Portal** | https://developer.ing.com/openbanking/home |
| **API Marketplace** | https://developer.ing.com/api-marketplace/marketplace |
| **Open Source SDK** | https://github.com/ing-bank/ing-open-banking-sdk |
| **API Standard** | Berlin Group NextGenPSD2 |
| **Auth** | OAuth 2.0 with mutual TLS (mTLS); eIDAS QWAC/QSealC |
| **SCA** | Web redirect + ING HomeBank app deeplink |
| **Sandbox** | Yes — ING Open Banking SDK includes sandbox support |

**API Products:**

| API | Type | Description |
|---|---|---|
| Account Information (AIS) | PSD2 | Accounts, balances, transactions |
| Payment Initiation (PIS) | PSD2 | Single and bulk payments (RON and EUR) |
| Confirmation of Funds | PSD2 | Fund availability check |
| **Payment Request API** | Premium | Request payments from counterparties |
| **Virtual Ledger Accounts** | Premium | Sub-account management for corporates |

**Get authorization URL (mTLS):**
```bash
curl -X GET "https://api.ing.com/oauth2/authorization-server-url?\
scope=payment-accounts:balances:view+payment-accounts:transactions:view&\
redirect_uri=https://your-app.com/callback&\
country_code=RO" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem \
  -H "Authorization: Bearer {application_token}"
```

---

### 3.5 Raiffeisen Bank Romania

**Part of RBI group API Marketplace. Cash Management APIs for corporates.**

| | |
|---|---|
| **Developer Portal (Production)** | https://developer.raiffeisen.ro/ |
| **Developer Portal (Test)** | https://developer-test.raiffeisen.ro/ |
| **RBI API Marketplace** | https://api.rbinternational.com/ |
| **API Standard** | Berlin Group NextGenPSD2 |
| **Auth** | OAuth 2.0 (Client Credentials Grant); eIDAS QWAC |
| **SCA** | Web redirect + mobile deeplink |
| **Sandbox** | Yes — test environment since March 2019 |

**API Products:**

| API | Type | Description |
|---|---|---|
| Accounts API (AISP) | PSD2 | Account list, balances, transaction history |
| Payments API (PISP) | PSD2 | Single, bulk, and periodic payments (RON/EUR) |
| Consent Management | PSD2 | Create, read, delete consents |
| Confirmation of Funds | PSD2 | Fund availability check |
| Authorization API | PSD2 | SCA flows |
| **Cash Management APIs** | RBI Premium | Corporate cash management via RBI Marketplace |

**First-contact (required to obtain Client-ID):**
```bash
curl -X POST https://developer.raiffeisen.ro/v1/first-contact \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem \
  -H "Content-Type: application/json" \
  -d '{"tppName": "Your Company", "tppRole": "AISP"}'
```

---

### 3.6 UniCredit Bank Romania

**Pan-European portal. All requests must be digitally signed.**

| | |
|---|---|
| **Developer Portal** | https://developer.unicredit.eu/ |
| **API Standard** | Berlin Group Implementation Guidelines |
| **Auth** | eIDAS QWAC/QSealC; all HTTP requests digitally signed |
| **SCA** | Redirect-based via UniCredit Mobile app |
| **Sandbox** | Yes — at developer.unicredit.eu |
| **Support** | psd2openapisupport.unicreditservices@unicredit.eu |

**API Products:**

| API | Type | Description |
|---|---|---|
| Accounts Service Group | PSD2 | List accounts, details, balances, transactions |
| Card Accounts Service Group | PSD2 | List card accounts, details, balances, transactions |
| Payments Service Group | PSD2 | Initiate payments, check status, read content |
| Consent APIs | PSD2 | Consent management |

**Note:** UniCredit Bank merged with Alpha Bank Romania in August 2025, creating an entity with ~11% market share.

---

### 3.7 Libra Internet Bank

**Leading fintech partner bank. Powers Revolut, Wise, and Raiffeisen Digital Bank AG backend.**

| | |
|---|---|
| **Developer Portal** | https://api.librabank.ro/devportal/ |
| **API Gateway** | https://api.librabank.ro/store/ |
| **Open Banking Page** | https://www.librabank.ro/Open-Banking |
| **Uptime Monitor** | https://stats.uptimerobot.com/BOK2OfVXG1 |
| **Auth** | Web redirect-based SCA; ConsumerKey/ConsumerSecret from portal |
| **Sandbox** | Yes — at api.librabank.ro |

**API Products:**

| API | Type | Description |
|---|---|---|
| API.Payments | PSD2 | Payment orders in RON from Libra accounts |
| API.Accounts | PSD2 | Balance and transaction history for any period |
| **API.Investigator** | Beyond PSD2 | Company data lookup by CUI — due diligence reports |

**Query company by CUI (API.Investigator):**
```bash
curl "https://api.librabank.ro/investigator/v1/company?cui=12345678" \
  -H "Authorization: Bearer {access_token}"
```

**Notable:**
- Banking infrastructure partner for **Revolut**, **Wise**, and **Raiffeisen Digital Bank AG**
- One of only 4 banks supporting fully automated bulk payments via open banking
- Supports collector accounts

---

## 4. Tier 2 Banks (Standard PSD2)

These banks offer PSD2-compliant APIs (AISP + PISP) with developer portals but no significant extensions beyond the PSD2 minimum.

### Summary Table

| Bank | Developer Portal | AISP | PISP | CoF | Sandbox | Notes |
|---|---|---|---|---|---|---|
| **Alpha Bank** | https://developer.api.alphabank.eu/ | Yes | Yes | Yes | Yes | Merged with UniCredit (Aug 2025). Group portal covers GR, CY, RO. QSealC required, all requests digitally signed. |
| **OTP Bank** | https://devch.otpdirekt.ro/prod-devch/developer-portal/ | Yes | Yes (RON) | — | Yes | Limited to 4 daily account data updates. Acquired by BT; portal status may be transitional. |
| **CEC Bank** | https://apiportal-test.cec.ro/cec/tpp/ | Yes | Yes (RON/EUR) | — | — | Implemented multibanking (connects to 9 other banks). PSD2 info: https://www.cec.ro/api-uri-psd2 |
| **Garanti BBVA** | https://developers.garantibbva.ro/ | Yes | Yes | Yes | Yes | Excellent performance per Finqware. 4-step onboarding: sign up → create app → sandbox → production. |
| **First Bank** | https://dev.firstbank.ro/openbanking/ | Yes | Yes (RON/EUR) | — | Yes | Good TPP onboarding. Supports simple, joint, and import signature types. |
| **Intesa Sanpaolo RO** | https://isbd.openbanking.intesasanpaolo.com/en/api_docs/isp-rom | Yes | Yes (RON only) | Yes | Yes | IAM sandbox: https://iam.sandbox.intesasanpaolobank.ro/. Support: tppsupport@intesasanpaolo.ro |
| **Patria Bank** | https://psd2api.patriabank.ro/DevelopmentPortal | Yes | Yes | — | Yes | Swagger: https://apigwpsd2.patriabank.ro/swagger. Test: https://psd2testapi.patriabank.ro/DevelopmentPortal. Support: psd2@patriabank.ro |
| **ProCredit Bank** | https://developer.procreditbank.ro/ | Yes | Yes | — | Yes | Group-wide portal: https://developer.procredit-group.com/. Live since July 2019. |
| **Vista Bank** | https://apimbr.marfinbank.ro/store/ | Yes | Yes | — | — | API docs PDF: https://www.vistabank.ro/public/docs/PSD2_API_Documentation_Vista_Bank.pdf |
| **Exim Banca Romaneasca** | https://api.eximbank.ro | Yes | Yes (RON only) | Yes | Yes | Open banking page: https://www.eximbank.ro/en/sandbox-persoane-fizice/ |
| **Credit Europe / Nexent** | https://developer.sandbox.crediteurope.ro/portal/ | Yes | Yes | Yes | Yes | Rebranded as Nexent Bank. Support: tppsupport@crediteurope.ro. Improved significantly. |
| **BRCI** | https://psd2.brci.ro/store/ | Yes | Yes | — | — | Standard PSD2 compliance. |
| **Porsche Bank** | https://www.porschebank.ro/ro/servicii-bancare/open-banking | Yes | Limited | — | — | Primarily auto financing bank. |
| **Orange Money** | https://www.orange.ro/money/psd2/index.html | Yes | Basic | — | — | E-money/payment institution, not a full bank. |

---

## 5. Neobanks & Fintechs

### 5.1 Salt Bank (Banca Transilvania subsidiary)

**Romania's first 100% digital neobank.**

| | |
|---|---|
| **Core Banking** | Engine by Starling Bank + AWS |
| **Customers** | 500,000+ in first year |
| **Public API** | No dedicated developer portal found |
| **Investment API** | Powered by Upvest (stocks, ETFs, digital assets) |

Salt Bank does not have a public developer portal. Open banking features (e.g., account top-ups from other banks) are implemented via Finqware's middleware.

### 5.2 Revolut (Operating in Romania)

**Most feature-rich business API for Romanian companies.**

| | |
|---|---|
| **Developer Portal** | https://developer.revolut.com/ |
| **Business API Docs** | https://developer.revolut.com/docs/business/business-api |
| **Open Banking API** | https://developer.revolut.com/docs/open-banking/open-banking-api |
| **Access** | Grow plan and above (Business accounts) |

**API Products:**

| API | Description |
|---|---|
| Accounts | Account management, balances, transaction details |
| Payments | Automated payouts, send money via link, instant/scheduled/draft payments |
| Batch Payments | Bulk payment creation |
| Cards | Card issuing and management |
| Exchange | Real-time exchange rates, currency exchange |
| Webhooks | Event notifications |
| Counterparties | Recipient management |

**Security Scopes:** `READ`, `WRITE`, `PAY`, `READ_SENSITIVE_CARD_DATA`

**List accounts:**
```bash
curl https://b2b.revolut.com/api/1.0/accounts \
  -H "Authorization: Bearer {access_token}"
```

**Create payment:**
```bash
curl -X POST https://b2b.revolut.com/api/1.0/pay \
  -H "Authorization: Bearer {access_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "request_id": "unique-request-id",
    "account_id": "{source_account_id}",
    "receiver": {
      "counterparty_id": "{counterparty_id}",
      "account_id": "{receiver_account_id}"
    },
    "amount": 1500.00,
    "currency": "RON",
    "reference": "Invoice 2025-001"
  }'
```

**Get transactions:**
```bash
curl "https://b2b.revolut.com/api/1.0/transactions?from=2025-01-01&to=2025-01-31&type=transfer" \
  -H "Authorization: Bearer {access_token}"
```

### 5.3 Wise (formerly TransferWise)

**International transfers with competitive exchange rates. Full business API.**

| | |
|---|---|
| **Developer Portal** | https://docs.wise.com/ |
| **Romania Office** | Piata Mihai Viteazu 3-4, Cluj-Napoca |
| **Access** | Business account holders; sandbox available instantly |
| **Romanian Banking Partner** | Libra Internet Bank |
| **Support** | api@wise.com |

**API Products:**

| API | Description |
|---|---|
| Transfers | Create, fund, and manage international transfers |
| Batch Payments | Bulk payment creation and management |
| Multi-Currency Accounts | Multi-currency balance management |
| Exchange Rates | Real-time and historical exchange rates |
| Recipients | Counterparty/recipient management |
| Webhooks | Transfer status notifications |

**Get exchange rate:**
```bash
curl "https://api.wise.com/v1/rates?source=RON&target=EUR" \
  -H "Authorization: Bearer {api_token}"
```

**Create transfer:**
```bash
# Step 1: Create quote
curl -X POST https://api.wise.com/v3/profiles/{profileId}/quotes \
  -H "Authorization: Bearer {api_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "sourceCurrency": "RON",
    "targetCurrency": "EUR",
    "sourceAmount": 5000,
    "targetAmount": null,
    "payOut": "BANK_TRANSFER"
  }'

# Step 2: Create recipient
curl -X POST https://api.wise.com/v1/accounts \
  -H "Authorization: Bearer {api_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "currency": "EUR",
    "type": "iban",
    "profile": "{profileId}",
    "accountHolderName": "Supplier SRL",
    "details": {"IBAN": "DE89370400440532013000"}
  }'

# Step 3: Create transfer
curl -X POST https://api.wise.com/v1/transfers \
  -H "Authorization: Bearer {api_token}" \
  -H "Content-Type: application/json" \
  -d '{
    "targetAccount": "{recipientId}",
    "quoteUuid": "{quoteId}",
    "customerTransactionId": "unique-id",
    "details": {"reference": "Invoice 2025-001"}
  }'
```

---

## 6. Document, Invoice & Statement Capabilities

This section directly addresses the core question: **what can you do with Romanian bank APIs regarding documents and invoices?**

### Invoice Upload/Download

**No Romanian bank offers invoice upload or download via their open banking APIs.**

E-invoicing in Romania is handled exclusively through the **ANAF e-Factura** system (`api.anaf.ro`). See the companion document `ANAF_SPV_API_Documentation.md` for full details.

The only bank with confirmed e-Factura integration in their banking app is **Banca Transilvania (BT Go)**, which allows users to:
- Log into ANAF SPV from within the banking app
- Auto-generate and submit e-invoices to ANAF
- Track ANAF processing status

This is a user-facing feature in the BT Go app, not an API.

### Transaction History (Digital Statements)

All 19 Romanian ASPSPs provide transaction history via their AISP APIs. Data is returned in **Berlin Group NextGenPSD2 JSON format**:

```bash
curl "https://{bank-api}/v1/accounts/{accountId}/transactions?\
dateFrom=2025-01-01&dateTo=2025-01-31&bookingStatus=booked" \
  -H "Authorization: Bearer {access_token}" \
  -H "Consent-ID: {consent_id}" \
  -H "X-Request-ID: $(uuidgen)" \
  --cert tpp-qwac.pem --key tpp-qwac-key.pem
```

**Response:**
```json
{
  "account": {"iban": "RO49AAAA1B31007593840000"},
  "transactions": {
    "booked": [
      {
        "transactionId": "txn-001",
        "bookingDate": "2025-01-15",
        "valueDate": "2025-01-15",
        "transactionAmount": {"currency": "RON", "amount": "-1500.00"},
        "creditorName": "Supplier SRL",
        "creditorAccount": {"iban": "RO15RZBR0000060019330955"},
        "remittanceInformationUnstructured": "Invoice 2025-001"
      }
    ],
    "pending": []
  }
}
```

### Formatted Statements

Formatted statement downloads in legacy banking formats (**MT940**, **CAMT.053**, **CSV**, **PDF**) are **NOT available** through PSD2 open banking APIs. These remain in each bank's proprietary internet/corporate banking channels.

### Bulk Payments

BNR mandated bulk payment API implementation for all banks. As of 2024, four banks support **fully automated** corporate bulk payments via open banking:

| Bank | Bulk Payments | Automation Level |
|---|---|---|
| **BCR** | Yes | Full automation |
| **ING** | Yes | Full automation |
| **BRD** | Yes | Full automation |
| **Libra Bank** | Yes | Full automation |
| Other banks | Yes (mandated) | Manual initiation (SCA per payment) |

Corporate bulk payments represent **77%** of open banking payment volume in Romania.

### Direct Debit

SEPA Direct Debit (Core and B2B schemes) is supported in Romania through **Transfond's SENT** system. The Single Mandate Register (RUM) centralizes all SEPA DD mandates. Direct debit APIs are **not part of PSD2** and are handled through each bank's proprietary corporate banking channels.

---

## 7. API Quality Ratings

Based on Finqware's comprehensive testing of 16 Romanian banking APIs for Corporate Treasury Automation:

| Bank | Rating | Notes |
|---|---|---|
| **UniCredit** | Reliable, excellent performance | Top-rated overall |
| **ING Bank** | Reliable, excellent data content | Rich transaction data |
| **BCR** | Reliable, excellent support | Responsive team |
| **Banca Transilvania** | Reliable, excellent support | Responsive team |
| **Raiffeisen Bank** | Reliable, good performance | Consistent |
| **Garanti BBVA** | Excellent performance | Best uptime |
| **Citi Bank** | Premium data content | Corporate-focused |
| **Credit Europe / Nexent** | Improved significantly | Was poor, now functional |
| **First Bank** | Reliable with progress | Good TPP onboarding |
| **OTP Bank** | Reliable with limitations | 4/day data limit |
| **Alpha Bank** | Reliable with obstacles | Unstructured transaction data |
| **Libra Bank** | Functional with limitations | Missing some data fields |
| **CEC Bank** | Reliable with performance issues | Consent deactivation issues |
| **BRD** | Extremely unreliable | Unavailable ~50% during testing |

**Note:** These ratings are from Finqware's testing period. By 2024, overall API error rates dropped to **0.8%** across the ecosystem, suggesting significant improvements.

---

## 8. Complete Developer Portal Reference

| # | Bank | Developer Portal / Sandbox URL |
|---|---|---|
| 1 | Banca Transilvania | https://apistorebt.ro/bt/sb/ |
| 2 | BCR (Erste Group) | https://developers.erstegroup.com/docs/guides/bcr-getting-started |
| 3 | BRD (Societe Generale) | https://www.devbrd.ro/brd/apicatalog/ |
| 4 | ING Bank Romania | https://developer.ing.com/openbanking/home |
| 5 | Raiffeisen Bank | https://developer.raiffeisen.ro/ (prod) / https://developer-test.raiffeisen.ro/ (test) |
| 6 | UniCredit Bank | https://developer.unicredit.eu/ |
| 7 | Libra Internet Bank | https://api.librabank.ro/devportal/ |
| 8 | Alpha Bank Romania | https://developer.api.alphabank.eu/ |
| 9 | OTP Bank Romania | https://devch.otpdirekt.ro/prod-devch/developer-portal/ |
| 10 | CEC Bank | https://apiportal-test.cec.ro/cec/tpp/ |
| 11 | Garanti BBVA | https://developers.garantibbva.ro/ |
| 12 | First Bank | https://dev.firstbank.ro/openbanking/ |
| 13 | Intesa Sanpaolo RO | https://isbd.openbanking.intesasanpaolo.com/en/api_docs/isp-rom |
| 14 | Patria Bank | https://psd2api.patriabank.ro/DevelopmentPortal |
| 15 | ProCredit Bank | https://developer.procreditbank.ro/ |
| 16 | Vista Bank | https://apimbr.marfinbank.ro/store/ |
| 17 | Exim Banca Romaneasca | https://api.eximbank.ro |
| 18 | Credit Europe / Nexent | https://developer.sandbox.crediteurope.ro/portal/ |
| 19 | BRCI | https://psd2.brci.ro/store/ |
| 20 | Porsche Bank | https://www.porschebank.ro/ro/servicii-bancare/open-banking |
| -- | Orange Money | https://www.orange.ro/money/psd2/index.html |
| -- | Revolut | https://developer.revolut.com/ |
| -- | Wise | https://docs.wise.com/ |

---

## 9. Payment Infrastructure

### Domestic Payment Systems

| System | Description |
|---|---|
| **SENT** (Sistemul Electronic National de Transfer) | Automated clearing house for retail interbank payments — credit transfers and direct debits |
| **Plati Instant** | Instant payments (processed within 10 seconds, 24/7/365). Supported by most major banks. |
| **ReGIS** | Real-Time Gross Settlement system for large-value payments |
| **SaFIR** | Securities settlement system |

### International

| System | Description |
|---|---|
| **SEPA Credit Transfer (SCT)** | EUR credit transfers across SEPA zone |
| **SEPA Direct Debit (SDD)** | EUR direct debits — Core and B2B schemes |
| **SEPA Instant Credit Transfer (SCT Inst)** | Instant EUR transfers (max 10 seconds) |
| **SWIFT** | International payments outside SEPA |

### Payment Currencies via Open Banking APIs

| Currency | Support |
|---|---|
| **RON** | All banks |
| **EUR** | Most banks (BT, BCR, BRD, ING, Raiffeisen, First Bank, CEC) |
| **Other currencies** | Only via Revolut and Wise business APIs |
