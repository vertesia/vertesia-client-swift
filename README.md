# Vertesia Swift Client

A Swift Package Manager client for the Vertesia API. Requires Swift 6 and supports iOS 17+ and macOS 14+.

## Installation

Add the Git URL `https://github.com/vertesia/vertesia-client-swift.git` in Xcode under **File → Add Package Dependencies**, then select the `VertesiaClient` product. During initial development, select the `main` branch.

```swift
dependencies: [
    .package(url: "https://github.com/vertesia/vertesia-client-swift.git", branch: "main")
]
```

Add `.product(name: "VertesiaClient", package: "vertesia-client-swift")` to the consuming target's dependencies.

## Usage

```swift
import VertesiaClient

let client = VertesiaClient(bearerToken: accessToken)
let account = try await client.accounts.getCurrentAccount()

let response = try await client.agentRuns.listAgentRunsRequest()
    .limit(20)
    .execute()
let runs = response.body.items
```

Provide a scoped Vertesia bearer token from your application's sign-in flow. To obtain a current token before each authenticated request, supply an asynchronous provider such as `VertesiaClient { try await session.accessToken() }`. The application owns refresh and secure storage. Each client has its own API configuration and send the API version associated with the checked-in contract.

The default endpoint is `https://api.vertesia.io/api/v1`. Pass `baseURL` to select a regional or other deployment endpoint. Additional generated resources are available through their API classes, for example `TasksAPI(apiConfiguration: client.apiConfiguration)`. Token Service methods belong to `TokenServiceAPI` with a separate configuration pointing to the STS host.

### Authentication

Use an issued access token or an async bearer-token provider when your app already owns sign-in. For other clients, the SDK also supports managed OAuth, API key exchange, and OIDC federation.

#### OAuth sign-in

Use the authorization and token endpoints from your registered OAuth client's issuer metadata. Start a PKCE request, present it with your app's system-browser sign-in, then pass the callback URL to the SDK. The SDK verifies the callback before exchanging the code.

```swift
let oauth = try VertesiaOAuthClient(
    clientID: clientID,
    authorizationEndpoint: authorizationEndpoint,
    tokenEndpoint: tokenEndpoint,
    redirectURI: redirectURI,
    resource: VertesiaClient.defaultBaseURL,
    scopes: ["offline_access", "content:read"],
    issuer: issuer
)
let authorization = try oauth.beginAuthorization()
let callback = try await signInInSystemBrowser(authorization.url)
let credentials = try await oauth.completeAuthorization(authorization, callback: callback)
let session = oauth.session(credentials: credentials) { refreshed in
    await saveCredentialsToKeychain(refreshed)
}
let client = VertesiaClient(oauth: session)
```

Save the initial credentials after sign-in and use `onRefresh` to save rotated refresh tokens. Recreate the session with the saved credentials when the app restarts. The `resource` is the Vertesia API base URL, including `/api/v1`.

#### API keys

Use an `sk-` key from your credential store. The SDK exchanges it through STS and sends the issued bearer token to the API. Hosted regional endpoints derive the corresponding STS host. Supply `tokenServerURL` for a custom deployment.

```swift
let client = try VertesiaClient(apiKey: apiKey, baseURL: apiURL)
```

#### OIDC federation

Configure the connection, project, and API resource for your federation policy. The assertion provider is called when the SDK needs a new token, so it should return a fresh assertion from your identity provider.

```swift
let federation = VertesiaFederationOptions(
    connectionID: connectionID,
    projectID: projectID,
    resource: apiURL,
    scope: "content:read"
) {
    try await identityProvider.freshAssertion()
}
let client = try VertesiaClient(federation: federation, baseURL: apiURL)
```

Supply `tokenEndpoint` when the federation policy uses a tenant-specific endpoint. The optional client authentication modes are `client_secret_basic`, `client_secret_post`, and `private_key_jwt`. Use `VertesiaClient.exchangeFederationToken` for a one-shot exchange.

### Request builders

Operations offer async convenience methods and `…WithRequestBuilder()` for access to the HTTP response. Operations with optional arguments also have typed `…Request()` builders. Pass required arguments at creation and set optional ones by name. Builders are values, so two queries can share a starting configuration. Call `build()` to customize headers before execution.

### Stream agent runs

Use `streamAgentRun` to read historical and live messages as they arrive on iOS and macOS. It uses the same bearer-token provider as other SDK calls and obtains a current token for each connection.

```swift
var cursor = AgentRunStreamCursor() // Or restore the cursor saved for this run.
for try await event in client.streamAgentRun(agentRunId: runID, resumingFrom: cursor) {
    render(event.message)
    cursor = event.cursor
}
```

The cursor is `Codable`. Save it after processing an event and supply it when you reopen the same run. Reconnects send `Last-Event-ID` when available and a `since` timestamp so they can also resume on servers that replay by timestamp. Transient streaming chunks are delivered without advancing the cursor.

The stream retries interrupted connections with bounded backoff. Cancel the consuming task when the view closes or when the app has received the messages it needs. Interactive runs can keep producing messages across turns. Archived replay and HTTP 204 responses close the sequence.

### Compatibility

- Model decoding accepts additional response fields. Explicitly modeled free-form JSON uses `JSONValue`.
- Unknown values in generated string and numeric enums decode as `.unknownDefaultOpenApi`. The sentinel cannot reproduce the original value when re-encoded.
- Generated `oneOf` unions retain unknown variants as `.unknownDefaultOpenApi(JSONValue)`, including nested nulls. A known discriminator still requires its declared branch to decode. Model options preserve mixed provider fields as an open JSON object. Other `anyOf` shapes use the upstream generator’s representations.
- Prompt and interaction references to projects and templates decode both ID strings and populated objects. Use the generated enum's `.typeString(id)` case when sending an ID.
- Agent-run messages use the native SSE client. Other SSE endpoints are outside the generated HTTP surface.

## Testing

Run the offline suite with `swift test`. It covers request builders, decoding, SSE, and authentication exchanges without credentials.

Pass Studio's shared fixture directory to run the same response fixtures used by the Go and Java SDKs.

```sh
VERTESIA_STUDIO_OPENAPI_FIXTURES=/path/to/studio/packages/api-specs/fixtures swift test
```

Live tests use an issued Vertesia bearer token and are opt-in. Use a test project with permissions for the read, prompt, interaction, data store, and content operations exercised by the suite. Lifecycle tests create uniquely named resources and clean them up.

```sh
export VERTESIA_BEARER_TOKEN="$(vertesia -p sdk-test auth token)"
VERTESIA_LIVE_TESTS=1 \
VERTESIA_API_URL=https://api-preview.us1.vertesia.io/api/v1 \
VERTESIA_PROJECT_ID=your-test-project-id \
swift test --filter LiveIntegrationTests
```

For a split development deployment, set `VERTESIA_STUDIO_URL` and `VERTESIA_ZENO_URL` in place of `VERTESIA_API_URL`. To exercise live SSE, also set `VERTESIA_TEST_AGENT_RUN_ID` to an existing run with persisted messages in that project. You can select an enabled model for the interaction execution test with `VERTESIA_TEST_EXECUTION_ENVIRONMENT` and `VERTESIA_TEST_EXECUTION_MODEL`.

## Regeneration

`spec/vertesia-openapi.json` is the published Vertesia API contract. The generation script uses the `swift6` and SwiftPM setup first exercised in Studio's mobile experiment. `scripts/regenerate.sh` regenerates the checked-in sources with OpenAPI Generator 7.27.0. It requires Java 11+ and Python 3. An existing generator JAR can be supplied via `OPENAPI_GENERATOR_JAR`.

```sh
scripts/regenerate.sh
swift test
scripts/regenerate.sh --check
```

The generated files live under `Sources/VertesiaClient/Generated`. Change the generation config or scripts to fix generated output. The default suite uses stubbed HTTP and runs without credentials.
