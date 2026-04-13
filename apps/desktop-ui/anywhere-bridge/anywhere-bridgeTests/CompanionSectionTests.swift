import Testing
@testable import anywhere_bridge

struct CompanionSectionTests {

    @Test(arguments: CompanionSection.allCases)
    func sectionMetadataIsPresent(for section: CompanionSection) {
        #expect(!section.rawValue.isEmpty)
        #expect(!section.title.isEmpty)
        #expect(!section.systemImage.isEmpty)
        #expect(!section.summary.isEmpty)
    }

    @Test
    func sectionTitlesAreUnique() {
        let titles = CompanionSection.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}
