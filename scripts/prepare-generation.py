"""Specialize the public OpenAPI contract and upstream Swift templates for this SDK."""

import json
import sys
from pathlib import Path
from zipfile import ZipFile

HTTP_METHODS = {"get", "put", "post", "delete", "options", "head", "patch", "trace"}


def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Expected one occurrence of {old!r} in upstream template")
    return source.replace(old, new)


def prepare_parameters(parameters):
    result = []
    for parameter in parameters:
        location = parameter.get("in")
        if location == "header" and parameter["name"].lower() == "x-api-version":
            continue

        # HTTP query values are text. Both an ISO string and stringified epoch
        # milliseconds are accepted by the server for these cost filters.
        schema = parameter.get("schema", {})
        types = schema.get("type")
        if location == "query" and isinstance(types, list) and set(types) == {"string", "number"}:
            parameter["schema"] = {"type": "string", "description": schema.get("description", "")}

        result.append(parameter)
    return result


def preserve_prompt_reference_shapes(spec):
    schemas = spec["components"]["schemas"]
    for name in ("Interaction", "InteractionPromptTemplateInput", "PromptTemplate"):
        project = schemas[name]["properties"]["project"]
        project["oneOf"] = project.pop("anyOf")
    for name in ("InteractionPromptSegmentInput", "PromptSegmentDef"):
        template = schemas[name]["properties"]["template"]
        template["oneOf"] = template.pop("anyOf")


def prepare_spec(source, destination):
    spec = json.loads(source.read_text())
    # Swift flattens anyOf into a struct and drops the string branch. Use the
    # union template for fields that accept an ID or a full reference object.
    preserve_prompt_reference_shapes(spec)
    for path, operations in list(spec["paths"].items()):
        # The transport sets the SDK's default API version once per client.
        if "parameters" in operations:
            operations["parameters"] = prepare_parameters(operations["parameters"])
        for method in HTTP_METHODS & operations.keys():
            operation = operations[method]
            if any(
                "text/event-stream" in response.get("content", {})
                for response in operation.get("responses", {}).values()
            ):
                del operations[method]
                continue

            if "parameters" in operation:
                operation["parameters"] = prepare_parameters(operation["parameters"])

        if not HTTP_METHODS & operations.keys():
            del spec["paths"][path]

    destination.write_text(json.dumps(spec))


def prepare_templates(jar, destination):
    destination.mkdir()
    with ZipFile(jar) as archive:
        api = archive.read("swift6/api.mustache").decode()
        one_of = archive.read("swift6/modelOneOf.mustache").decode()

    # API resources only carry the generator's synchronized client configuration.
    declaration = (
        "{{#nonPublicApi}}internal{{/nonPublicApi}}"
        "{{^nonPublicApi}}open{{/nonPublicApi}} class {{classname}}"
        "{{#objcCompatible}} : NSObject{{/objcCompatible}}"
    )
    api = replace_once(api, declaration, "public final class {{classname}}: Sendable")
    api = api.replace("{{#nonPublicApi}}internal{{/nonPublicApi}}{{^nonPublicApi}}open{{/nonPublicApi}}",
                      "public")
    api = api.replace(
        "withAllowedCharacters: .urlPathAllowed",
        'withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/%"))',
    )
    (destination / "api.mustache").write_text(api)

    # Java and Python SDKs preserve unknown union values, including embedded JSON nulls.
    one_of = replace_once(one_of, "case unknownDefaultOpenApi\n", "case unknownDefaultOpenApi(JSONValue)\n")
    one_of = replace_once(
        one_of,
        "case .unknownDefaultOpenApi:\n            try container.encodeNil()",
        "case .unknownDefaultOpenApi(let raw):\n            try container.encode(raw)",
    )
    if one_of.count("self = .unknownDefaultOpenApi\n") != 2:
        raise ValueError("Expected discriminator and structural union fallbacks")
    one_of = one_of.replace(
        "self = .unknownDefaultOpenApi\n", "self = .unknownDefaultOpenApi(try JSONValue(from: decoder))\n"
    )
    (destination / "modelOneOf.mustache").write_text(one_of)


if __name__ == "__main__":
    source, jar, scratch = map(Path, sys.argv[1:])
    prepare_spec(source, scratch / "openapi.json")
    prepare_templates(jar, scratch / "templates")
