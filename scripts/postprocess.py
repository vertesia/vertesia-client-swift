"""Apply Swift generator workarounds and add typed operation builders."""

import json
import re
import sys
from pathlib import Path

# AgentMessageType wire values from @vertesia/common's store/workflow.ts.
MESSAGE_KINDS = (
    "system", "thought", "plan", "update", "complete", "warning", "error",
    "answer", "question", "requestInput", "idle", "terminated",
    "streamingChunk", "batchProgress", "restarting",
)
REQUEST_METHOD = re.compile(
    r"^    public func (\w+)WithRequestBuilder\((.*)\) -> RequestBuilder<(.+)> \{$",
    re.MULTILINE,
)
PARAMETER = re.compile(r"(\w+|`\w+`): (.+?)( = nil)?$")


def insert_builders(source):
    # The pinned generator emits plain either required or nil-defaulted parameters.
    # Expose the required arguments at the factory and optional arguments as setters.
    builders = []
    for match in REQUEST_METHOD.finditer(source):
        operation, signature, result = match.groups()
        required, optional, arguments = [], [], []
        for parameter in signature.split(", ") if signature else []:
            parsed = PARAMETER.fullmatch(parameter)
            if not parsed:
                raise ValueError(f"Unhandled parameter for {operation}: {parameter}")
            name, type_name, default = parsed.groups()
            arguments.append(f"{name}: self.{name}")
            (optional if default else required).append((name, type_name))

        if not optional:
            continue

        type_name = operation[0].upper() + operation[1:] + "CallBuilder"
        builder = [
            f"    public struct {type_name}: Sendable {{",
            "        fileprivate let apiResource: " + source.split("public final class ", 1)[1].split(":", 1)[0],
        ]
        builder.extend(f"        fileprivate let {name}: {param_type}" for name, param_type in required)
        builder.extend(
            f"        fileprivate var {name}: {param_type} = nil" for name, param_type in optional
        )
        for name, param_type in optional:
            builder += [
                "",
                f"        public func {name}(_ value: {param_type}) -> Self {{",
                "            var copy = self",
                f"            copy.{name} = value",
                "            return copy",
                "        }",
            ]
        builder += [
            "",
            f"        public func build() -> RequestBuilder<{result}> {{",
            f"            apiResource.{operation}WithRequestBuilder({', '.join(arguments)})",
            "        }",
            "",
            f"        public func execute() async throws(ErrorResponse) -> Response<{result}> {{",
            "            try await build().execute()",
            "        }",
            "    }",
            "",
            f"    public func {operation}Request("
            + ", ".join(f"{name}: {param_type}" for name, param_type in required)
            + f") -> {type_name} {{",
            f"        {type_name}(apiResource: self"
            + "".join(f", {name}: {name}" for name, _ in required)
            + ")",
            "    }",
        ]
        builders.append("\n".join(builder))

    if not builders:
        return source
    end = source.rfind("\n}")
    if end == -1:
        raise ValueError("Swift API resource has no closing brace")
    return source[:end] + "\n\n" + "\n\n".join(builders) + source[end:]


def make_enum_compatibility_fixes(models):
    for path in models.glob("*.swift"):
        original = path.read_text()
        source = original
        # Swift's generator skips the fallback decoder for some numeric enums.
        source = re.sub(
            r"(enum \w+: (?:Int(?:32|64)?|Float|Double), [^\n]+, CaseIterable) \{"
            r"(?=\n[^{}]*case unknownDefaultOpenApi = )",
            r"\1, CaseIterableDefaultsLast {",
            source,
        )
        if path.name == "AgentMessageType.swift":
            for value, name in enumerate(MESSAGE_KINDS):
                source = source.replace(f"case _{value} = {value}\n", f"case {name} = {value}\n")
            if "case restarting = 14" not in source:
                raise ValueError("AgentMessageType mapping no longer matches the generated enum")
        if source != original:
            path.write_text(source)


def preserve_request_cancellation(infrastructure):
    # An async token provider can finish after the caller has canceled the builder.
    models = infrastructure / "Models.swift"
    source = models.read_text()
    start = source.index("public final class RequestTask:")
    end = source.index("\n}", start) + 2
    request_task = """public final class RequestTask: Sendable {
    private struct State {
        var task: URLSessionDataTaskProtocol?
        var cancelled = false
    }

    private let state = OpenAPIMutex(State())

    internal func set(task: URLSessionDataTaskProtocol) {
        let cancelled = state.withValue { state in
            state.task = task
            return state.cancelled
        }
        if cancelled {
            task.cancel()
        }
    }

    internal func takeTask() -> URLSessionDataTaskProtocol? {
        state.withValue { state in
            let task = state.task
            state.task = nil
            return task
        }
    }

    public func cancel() {
        let task = state.withValue { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}"""
    models.write_text(source[:start] + request_task + source[end:])
    implementation = infrastructure / "URLSessionImplementations.swift"
    source = implementation.read_text()
    old = "requestTask.get()"
    if source.count(old) != 1:
        raise ValueError("Generated URLSession task cleanup changed")
    implementation.write_text(source.replace(old, "requestTask.takeTask()"))


def format_whole_query_numbers(infrastructure):
    path = infrastructure / "Extensions.swift"
    source = path.read_text()
    old = """extension Double: ParameterConvertible {
    func asParameter(codableHelper: CodableHelper) -> any Sendable { self }
}"""
    new = """extension Double: ParameterConvertible {
    func asParameter(codableHelper: CodableHelper) -> any Sendable {
        if let integer = Int64(exactly: self) {
            return integer
        }
        return self
    }
}"""
    if source.count(old) != 1:
        raise ValueError("Generated Double query conversion changed")
    path.write_text(source.replace(old, new))


def write_api_version(root, spec):
    version = spec["info"]["x-api-version"]
    if not re.fullmatch(r"\d{8}", version):
        raise ValueError(f"Invalid API version: {version!r}")
    configuration = root / "Infrastructure" / "APIs.swift"
    source = configuration.read_text()
    original = "customHeaders: [String: String] = [:],"
    if source.count(original) != 1:
        raise ValueError("Generated API configuration default headers changed")
    configuration.write_text(source.replace(
        original, f'customHeaders: [String: String] = ["x-api-version": "{version}"],'
    ))
    (root / "Infrastructure" / "APIVersion.swift").write_text(
        "// Generated by scripts/regenerate.sh\n\n"
        f'public extension VertesiaClient {{\n    static let apiVersion = "{version}"\n}}\n'
    )


if __name__ == "__main__":
    root, spec = map(Path, sys.argv[1:])
    (root / "Models" / "ModelOptions.swift").unlink()
    make_enum_compatibility_fixes(root / "Models")
    for api in (root / "APIs").glob("*.swift"):
        api.write_text(insert_builders(api.read_text()))
    write_api_version(root, json.loads(spec.read_text()))
    preserve_request_cancellation(root / "Infrastructure")
    format_whole_query_numbers(root / "Infrastructure")
    for path in root.rglob("*.swift"):
        source = path.read_text()
        normalized = "\n".join(line.rstrip() for line in source.splitlines()).rstrip() + "\n"
        if normalized != source:
            path.write_text(normalized)
