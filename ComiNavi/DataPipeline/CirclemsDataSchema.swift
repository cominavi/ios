//
//  CirclemsData.swift
//  ComiNavi
//
//  Created by Galvin Gao on 9/13/24.
//

import Foundation
import GRDB

/// https://github.com/Circlems/WebcatalogApi/wiki/%E3%83%87%E3%83%BC%E3%82%BF%E3%83%99%E3%83%BC%E3%82%B9%E4%BB%95%E6%A7%98%E6%9B%B8
enum CirclemsDataSchema {
    /// **地区情報**
    ///
    /// 地区の名前と対応する地図の情報です。
    /// > 例: 東1,東2,東3,東123壁 ...
    struct ComiketAreaWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// 地区ID
        var id: Int
        /// 地区名 例:「東1」
        var name: String?
        /// 地区名(簡素版) 例:「東」
        var simpleName: String?
        /// 対応地図ID
        var mapId: Int
        /// 印刷用範囲
        var x: Int?
        /// 印刷用範囲
        var y: Int?
        /// 印刷用範囲
        var w: Int?
        /// 印刷用範囲
        var h: Int?
        /// 略地図ファイル名基幹部
        var allFilename: String?
        /// 印刷用範囲ハイレゾ用
        var x2: Int?
        /// 印刷用範囲ハイレゾ用
        var y2: Int?
        /// 印刷用範囲ハイレゾ用
        var w2: Int?
        /// 印刷用範囲ハイレゾ用
        var h2: Int?
    }

    /// **ブロック情報**
    ///
    /// ブロックの名前と対応する地区の情報です。
    /// > 例: あ、Ａ
    struct ComiketBlockWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// ブロックID
        var id: Int
        /// ブロック名
        var name: String?
        /// 対応地区ID
        var areaId: Int
    }

    /// **サークル拡張情報**
    ///
    /// サークル情報に追加してWebカタログ向けのサークル追加情報です。
    struct ComiketCircleExtend: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// サークルID(DVDのみ)
        var id: Int
        /// 公開サークルID
        var WCId: Int
        /// twitterURL
        var twitterURL: String?
        /// pixivURL
        var pixivURL: String?
        /// Circle.msポータルのサークル詳細URL
        var CirclemsPortalURL: String?
    }

    /// **サークル情報**
    ///
    /// その回のコミケットに参加しているサークルの情報です。
    struct ComiketCircleWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// サークルID
        var id: Int
        /// ページ番号 漏れの場合は 0
        var pageNo: Int?
        /// カットインデックス 漏れの場合は 0
        var cutIndex: Int?
        /// 参加日 漏れの場合は 0
        var day: Int?
        /// ブロックID 漏れの場合は 0
        var blockId: Int?
        /// スペース番号 漏れの場合は 0
        var spaceNo: Int?
        /// スペース番号補助 0:a 1:b
        var spaceNoSub: Int?
        /// ジャンルID
        var genreId: Int?
        /// サークル名
        var circleName: String?
        /// サークル名(読みがな) 全角カナで正規化
        var circleKana: String?
        /// 執筆者名
        var penName: String?
        /// 発行誌名
        var bookName: String?
        /// URL
        var url: String?
        /// メールアドレス
        var mailAddr: String?
        /// 補足説明
        var description: String?
        /// サークルメモ
        var memo: String?
        /// 更新用ID
        ///
        /// updateIdは各開催ごとにサークルを一意に識別する値となります。
        /// 初期データベースの更新時に通常のIdについてはサークルの公開状態により変動いたしますが、
        /// updateIdにつきましてはすべてのデータ共通で一意に変動することなく割り振られます。
        /// （同様の割り振りとしてComiketCircleExtendのwcIdもございますが、こちらはすべての開催回を通して一意のIdが割り振られます。
        /// また、DVD-ROMカタログ、Webカタログからエクスポートされましたチェックリストのサークルシリアル番号とも共通の値となり、
        /// updateIdによりチェックリスト内のサークルの識別にも利用が可能です。
        var updateId: Int?
        /// 更新情報
        var updateData: String?
        /// Circle.ms URL
        var circlems: String?
        /// RSS
        var rss: String?
        /// 更新フラグ
        var updateFlag: Int?
    }

    /// **開催日程情報**
    ///
    /// コミケットの開催日程情報です。
    /// > 例: 1日目、2日目……
    struct ComiketDateWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// 日程ID(初日が1)
        var id: Int
        /// 年
        var year: Int?
        /// 月
        var month: Int?
        /// 日
        var day: Int?
        /// 曜日 (1:日 ～ 7:土)
        var weekday: Int?
    }

    /// **floor情報**
    ///
    /// 開催ごとに動的なfloor値の取得用テーブル
    struct ComiketFloorWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// floorの指定値
        var id: Int
        /// floorの名称
        var name: String?
        /// 日程ID(1日目 = 1)
        var day: Int
        /// ComiketMapWC の id
        var mapId: Int
    }

    /// **ジャンル情報**
    ///
    /// ジャンルの(コード + 名前)情報と対応する地区の情報です。
    /// 参加日(day)については1 ～ 3の日付、または特定の日に固定できないジャンルにつきましては 0 に設定されています。
    /// > 例: 200(PCギャルゲ─)
    struct ComiketGenreWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// ジャンルID
        var id: Int
        /// ジャンル名
        var name: String?
        /// ジャンルコード
        var code: Int?
        /// 参加日
        var day: Int?
    }

    /// **表示基本情報**
    struct ComiketInfoWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// コミケ名称
        var comiketName: String?
        /// サークルカット幅
        var cutSizeW: Int?
        /// サークルカット高さ
        var cutSizeH: Int?
        /// サークルカット原点X
        var cutOriginX: Int?
        /// サークルカット原点Y
        var cutOriginY: Int?
        /// サークルカットオフセット(X方向)
        var cutOffsetX: Int?
        /// サークルカットオフセット(Y方向)
        var cutOffsetY: Int?
        /// マップ机サイズ幅
        var mapSizeW: Int?
        /// マップ机サイズ高さ
        var mapSizeH: Int?
        /// マップ机表示原点X
        var mapOriginX: Int?
        /// マップ机表示原点Y
        var mapOriginY: Int?
        /// マップ机サイズ幅ハイレゾ用
        var map2SizeW: Int?
        /// マップ机サイズ高さハイレゾ用
        var map2SizeH: Int?
        /// マップ机表示原点Xハイレゾ用
        var map2OriginX: Int?
        /// マップ机表示原点Yハイレゾ用
        var map2OriginY: Int?
    }

    /// **マップ配置情報**
    ///
    /// マップ配置のための情報を格納したテーブルです。
    /// ※mapId は結合により取得できるため冗長な情報ですが
    /// 検索の高速化のために設けられています。
    struct ComiketLayoutWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// ブロックID
        var blockId: Int?
        /// スペース番号
        var spaceNo: Int?
        /// マップ上での座標
        var xpos: Int?
        /// マップ上での座標
        var ypos: Int?
        /// マップ上での座標ハイレゾ用
        var xpos2: Int?
        /// マップ上での座標ハイレゾ用
        var ypos2: Int?
        /// テーブルのレイアウト
        ///
        /// テーブルの向きを表します。テーブルのレイアウトは次のようになる。
        /// - aが左: 1
        /// - aが下: 2
        /// - aが右: 3
        /// - aが上: 4
        var layout: Int?
        /// マップID
        var mapId: Int?
        /// ホールID（壁を判断しない）
        var hallId: Int?
    }

    /// **各情報のマッピングテーブル**
    ///
    /// 日程、マップ、地区、floor、ブロックの連携情報
    struct ComiketMappingWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// 日程ID(1日目 = 1)
        var day: Int
        /// ComiketMapWC の id
        var mapId: Int
        /// 対応地区ID
        var areaId: Int
        /// 対応floorの指定値
        var floorId: Int
        /// ブロックID
        var blockId: Int
    }

    /// **地図情報**
    ///
    /// 地図画像ファイルを識別するための情報です。
    /// > 例: 東123, 東456 ...
    struct ComiketMapWC: Codable, FetchableRecord, PersistableRecord {
        /// コミケ番号
        var comiketNo: Int
        /// 地図ID
        var id: Int
        /// 地図名
        var name: String?
        /// 地図ファイル名基幹部
        var filename: String?
        /// 印刷用範囲
        var x: Int?
        /// 印刷用範囲
        var y: Int?
        /// 印刷用範囲
        var w: Int?
        /// 印刷用範囲
        var h: Int?
        /// 略地図ファイル名基幹部
        var allFilename: String?
        /// 印刷用範囲ハイレゾ用
        var x2: Int?
        /// 印刷用範囲ハイレゾ用
        var y2: Int?
        /// 印刷用範囲ハイレゾ用
        var w2: Int?
        /// 印刷用範囲ハイレゾ用
        var h2: Int?
        /// 配置に対する回転方向 0:正 1:逆
        var rotate: Int?
    }
}
