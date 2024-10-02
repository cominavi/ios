//
//  AppDataSource.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/1/24.
//

import Foundation

enum AppData {
    // CirclemsDataSource shall be initialized by EntryView
    public static var circlems: CirclemsDataSource!
    public static var user = UserState()
}

class UserState: ObservableObject {
    @Published var accessToken: String?
    @Published var name: String?

    var isLoggedIn: Bool {
        return accessToken != nil
    }
}
