// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "CominaviAPIClient",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "CominaviAPIClient", targets: ["CominaviAPIClient"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-openapi-generator",
            exact: "1.13.0"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-runtime",
            exact: "1.12.0"
        ),
        .package(
            url: "https://github.com/apple/swift-openapi-urlsession",
            exact: "1.3.1"
        ),
        .package(
            url: "https://github.com/apple/swift-http-types",
            exact: "1.6.0"
        )
    ],
    targets: [
        .target(
            name: "CominaviAPIClient",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HTTPTypesFoundation", package: "swift-http-types")
            ],
            plugins: [
                .plugin(
                    name: "OpenAPIGenerator",
                    package: "swift-openapi-generator"
                )
            ]
        ),
        .testTarget(
            name: "CominaviAPIClientTests",
            dependencies: ["CominaviAPIClient"]
        )
    ]
)
