//
//  Models.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/2/24.
//

import Foundation

struct GetWebCatalogDBResponse: Codable, Equatable, Sendable {
    struct Response: Codable, Equatable, Sendable {
        struct Databases: Codable, Equatable, Sendable {
            let textdbSqlite3URLSSL, imagedb1URLSSL, imagedb2URLSSL: String
            let textdbSqlite3ZipURLSSL, imagedb1ZipURLSSL, imagedb2ZipURLSSL: String

            enum CodingKeys: String, CodingKey {
                case textdbSqlite3URLSSL = "textdb_sqlite3_url_ssl"
                case imagedb1URLSSL = "imagedb1_url_ssl"
                case imagedb2URLSSL = "imagedb2_url_ssl"
                case textdbSqlite3ZipURLSSL = "textdb_sqlite3_zip_url_ssl"
                case imagedb1ZipURLSSL = "imagedb1_zip_url_ssl"
                case imagedb2ZipURLSSL = "imagedb2_zip_url_ssl"
            }
        }

        let url, md5: Databases
        let updatedate: String
    }

    let response: Response
    let status: String
}
