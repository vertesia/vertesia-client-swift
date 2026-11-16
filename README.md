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

### Request builders

Operations offer async convenience methods and `…WithRequestBuilder()` for access to the HTTP response. Operations with optional arguments also have typed `…Request()` builders. Pass required arguments at creation and set optional ones by name. Builders are values, so two queries can share a starting configuration. Call `build()` to customize headers before execution.

### Compatibility

- Model decoding accepts additional response fields. Explicitly modeled free-form JSON uses `JSONValue`.
- Unknown values in generated string and numeric enums decode as `.unknownDefaultOpenApi`. The sentinel cannot reproduce the original value when re-encoded.
- Generated `oneOf` unions retain unknown variants as `.unknownDefaultOpenApi(JSONValue)`, including nested nulls. A known discriminator still requires its declared branch to decode. Model options preserve mixed provider fields as an open JSON object. Other `anyOf` shapes use the upstream generator’s representations.
- Server-sent event operations are currently outside the package's generated HTTP surface.

## Regeneration

`spec/vertesia-openapi.json` is the published Vertesia API contract. The generation script uses the `swift6` and SwiftPM setup first exercised in Studio's mobile experiment. `scripts/regenerate.sh` regenerates the checked-in sources with OpenAPI Generator 7.27.0. It requires Java 11+ and Python 3. An existing generator JAR can be supplied via `OPENAPI_GENERATOR_JAR`.

```sh
scripts/regenerate.sh
swift test
scripts/regenerate.sh --check
```

The generated files live under `Sources/VertesiaClient/Generated`. Change the generation config or scripts to fix generated output. The test suite uses a local stub for HTTP and runs without credentials.
