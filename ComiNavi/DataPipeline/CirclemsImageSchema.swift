//
//  CirclemsImageSchema.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Foundation
import GRDB

/// https://github.com/Circlems/WebcatalogApi/wiki/%E5%88%9D%E6%9C%9F%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9
enum CirclemsImageSchema {
    struct ComiketCircleImage: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        ///
        /// > 例: `104`
        var comiketNo: Int
        /// サークルID(DB内のみで通用する)
        var id: Int
        /// 公開サークルID
        var WCId: Int
        /// 横幅 (pixels)
        var width: Int
        /// 縦幅 (pixels)
        var height: Int
        /// イメージタイプ (拡張子)
        ///
        /// > 例: `png`
        var type: String
        /// 画像サイズ (bytes)
        var size: Int
        /// MD5ハッシュ
        var md5: Data?
        /// バイナリ画像データ
        var cutImage: Data?
    }

    struct ComiketCommonImage: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// イメージ名
        var name: String
        /// 横幅 (pixels)
        var width: Int
        /// 縦幅 (pixels)
        var height: Int
        /// イメージタイプ(拡張子)
        ///
        /// > 例: `png`
        var type: String
        /// 画像サイズ (bytes)
        var size: Int
        /// MD5ハッシュ
        var md5: Data?
        /// バイナリ画像データ
        var image: Data?
    }
}
