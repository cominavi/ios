//
//  AppTrack.swift
//  ComiNavi
//
//  Created by Galvin Gao on 10/6/24.
//

import Foundation
import PostHog
import Sentry

enum AppTrack {
    enum UserIntent: String, CaseIterable, Sendable {
        case favoriteAdded = "favorite.add"
        case favoriteRemoved = "favorite.remove"
        case favoriteColorChanged = "favorite.color_change"
        case favoritesImported = "favorite.import"
        case favoriteRecoveryDiscarded = "favorite.recovery_discard"
        case followingImportStarted = "following_import.start"

        case authenticationStarted = "authentication.start"
        case identityLinkStarted = "authentication.identity_link"
        case signOutStarted = "authentication.sign_out"
        case accountDeletionRequested = "profile.account_delete"
        case profileUpdated = "profile.update"
        case eventReminderChanged = "reminder.change"

        case sharedPlanCreated = "shared_plan.create"
        case sharedPlanRenamed = "shared_plan.rename"
        case sharedPlanArchived = "shared_plan.archive"
        case sharedPlanReopened = "shared_plan.reopen"
        case sharedPlanInvitationAccepted = "shared_plan.invitation_accept"
        case sharedPlanMemberRevoked = "shared_plan.member_revoke"
        case sharedPlanMemberReinstated = "shared_plan.member_reinstate"
        case sharedPlanOwnershipTransferred = "shared_plan.ownership_transfer"
        case sharedPlanInvitationCreated = "shared_plan.invitation_create"
        case sharedPlanInvitationRevoked = "shared_plan.invitation_revoke"
        case sharedPlanFavoritesImported = "shared_plan.favorites_import"
        case sharedPlanCircleAdded = "shared_plan.circle_add"
        case sharedPlanCircleRemoved = "shared_plan.circle_remove"
        case sharedPlanMemoUpdated = "shared_plan.memo_update"
        case sharedPlanPurchaseNeedCreated = "shared_plan.purchase_need_create"
        case sharedPlanPurchaseNeedDeleted = "shared_plan.purchase_need_delete"
        case sharedPlanWantedQuantityUpdated = "shared_plan.wanted_quantity_update"
        case sharedPlanPurchaseProgressUpdated = "shared_plan.purchase_progress_update"
        case sharedPlanBuyerAllocationUpdated = "shared_plan.buyer_allocation_update"
        case sharedPlanFulfilledQuantityUpdated = "shared_plan.fulfilled_quantity_update"
        case sharedPlanCommunicationUpdated = "shared_plan.communication_update"
        case sharedPlanConflictResolved = "shared_plan.conflict_resolve"
        case sharedPlanUnsyncedContentDiscarded = "shared_plan.unsynced_content_discard"
        case sharedPlanUnsyncedContentRebased = "shared_plan.unsynced_content_rebase"
        case sharedPlanMetadataRetry = "shared_plan.metadata_retry"
        case sharedPlanMetadataDiscarded = "shared_plan.metadata_discard"

        var category: String {
            switch self {
            case .favoriteAdded,
                 .favoriteRemoved,
                 .favoriteColorChanged,
                 .favoritesImported,
                 .favoriteRecoveryDiscarded:
                "user.favorite"
            case .followingImportStarted:
                "user.following_import"
            case .authenticationStarted, .identityLinkStarted, .signOutStarted:
                "user.authentication"
            case .accountDeletionRequested, .profileUpdated:
                "user.profile"
            case .eventReminderChanged:
                "user.reminder"
            case .sharedPlanCreated,
                 .sharedPlanRenamed,
                 .sharedPlanArchived,
                 .sharedPlanReopened,
                 .sharedPlanInvitationAccepted,
                 .sharedPlanMemberRevoked,
                 .sharedPlanMemberReinstated,
                 .sharedPlanOwnershipTransferred,
                 .sharedPlanInvitationCreated,
                 .sharedPlanInvitationRevoked,
                 .sharedPlanFavoritesImported,
                 .sharedPlanCircleAdded,
                 .sharedPlanCircleRemoved,
                 .sharedPlanMemoUpdated,
                 .sharedPlanPurchaseNeedCreated,
                 .sharedPlanPurchaseNeedDeleted,
                 .sharedPlanWantedQuantityUpdated,
                 .sharedPlanPurchaseProgressUpdated,
                 .sharedPlanBuyerAllocationUpdated,
                 .sharedPlanFulfilledQuantityUpdated,
                 .sharedPlanCommunicationUpdated,
                 .sharedPlanConflictResolved,
                 .sharedPlanUnsyncedContentDiscarded,
                 .sharedPlanUnsyncedContentRebased,
                 .sharedPlanMetadataRetry,
                 .sharedPlanMetadataDiscarded:
                "user.shared_plan"
            }
        }
    }

    static func userIntent(_ intent: UserIntent, data: [String: Any] = [:]) {
        SentrySDK.addBreadcrumb(userIntentBreadcrumb(intent, data: data))
    }

    static func userIntentBreadcrumb(
        _ intent: UserIntent,
        data: [String: Any] = [:]
    ) -> Breadcrumb {
        let breadcrumb = Breadcrumb()
        breadcrumb.type = "user"
        breadcrumb.level = .info
        breadcrumb.category = intent.category
        breadcrumb.message = intent.rawValue
        if !data.isEmpty {
            breadcrumb.data = data
        }
        return breadcrumb
    }

    static func user(_ user: User?) {
        if let user = user, let userId = user.userId, let nickname = user.nickname {
            SentrySDK.configureScope { scope in
                let sentryUser = Sentry.User(userId: userId.string)
                sentryUser.name = nickname
                scope.setUser(sentryUser)
            }

            PostHogSDK.shared.identify(userId.string, userProperties: [
                "name": nickname,
                "circlems_preferences_r18enabled": user.preferenceR18Enabled as Any
            ])
        } else {
            SentrySDK.configureScope { scope in
                scope.setUser(nil)
            }

            PostHogSDK.shared.reset()
        }
    }
}
