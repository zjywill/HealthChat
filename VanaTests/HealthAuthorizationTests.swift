import Foundation
import HealthKit
import Testing

@testable import Vana

/// 授权请求里到底问了哪些类型。
///
/// 盯的是 2026-08-21 那次审核撞上的那条:iPad Air (M4) 上按设置页那颗「请求读取 Apple 健康」,
/// 那一行就一直停在「正在请求…」——面板没弹出来,请求也没回话。启动时那次请求在同一台设备上
/// 照常弹了面板,两次的差别只有一处:设置页那次多带了病历(FHIR)那两个类型,而 SDK 头文件
/// 里明写着 "Call supportsHealthRecords before attempting to request authorization for any
/// clinical types"。
///
/// `supportsHealthRecords` 是真机上的地区/账号状态,测试里造不出那台设备,所以判断被拆成了
/// 一个纯函数,那个 Bool 从外面传进来。
@Suite("Health authorization")
struct HealthAuthorizationTests {

    private func isClinical(_ type: HKObjectType) -> Bool { type is HKClinicalType }

    @Test("这台设备上没有「健康记录」时,病历类型一个都不问")
    func skipsClinicalTypesWhenUnsupported() {
        let requested = HealthStore.requestedTypes(force: true, supportsHealthRecords: false)

        #expect(!requested.contains(where: isClinical))
        // 剩下的照问:少问一个病历类型,不该顺手把血压也丢了——那颗按钮的一半理由就是
        // 「新增的数据类型要重新请求」。
        #expect(requested.contains(HKQuantityType(.bloodPressureSystolic)))
        #expect(requested.contains(HKQuantityType(.stepCount)))
    }

    @Test("支持的设备上照问,这条修的是问不到的那种设备")
    func asksForClinicalTypesWhenSupported() {
        let requested = HealthStore.requestedTypes(force: true, supportsHealthRecords: true)

        #expect(requested.contains(HKClinicalType(.labResultRecord)))
        #expect(requested.contains(HKClinicalType(.vitalSignRecord)))
    }

    @Test("启动时那次不问病历,也不问血压——那两类是按需申请的")
    func launchRequestStaysOnTheEverydayTypes() {
        let requested = HealthStore.requestedTypes(force: false, supportsHealthRecords: true)

        #expect(!requested.contains(where: isClinical))
        #expect(!requested.contains(HKQuantityType(.bloodPressureSystolic)))
        #expect(requested.contains(HKCategoryType(.sleepAnalysis)))
    }

    /// 「这台设备上没有这个功能」和「没有记录」是两件事。前者让用户去「健康」App 里连医院
    /// 是白跑一趟——这条路上永远连不上,该说的是让他拍一张。
    @Test("读不到病历时说的是拍一张，不是去连医院")
    func unavailableReportPointsAtThePhotoPath() {
        let report = HealthTools.healthRecordsUnavailableReport

        let note = report.notes.joined()
        #expect(note.contains("健康记录"))
        #expect(note.contains("拍一张"))
        #expect(!note.contains("连接医院"))
        #expect(report.isEmpty)
    }
}
