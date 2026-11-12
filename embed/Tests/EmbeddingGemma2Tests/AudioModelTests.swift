import Testing
@testable import EmbeddingGemma2

@Suite("Audio attention mask")
struct AudioModelTests {
    @Test func includesAllThirteenLeftContextPositions() {
        let mask=Array(repeating:Int32(1),count:25)

        for key in 0...12 {
            #expect(AudioModel.attentionAllows(query:12,key:key,count:mask.count,mask:mask))
        }
        #expect(!AudioModel.attentionAllows(query:12,key:13,count:mask.count,mask:mask))
    }

    @Test func keepsTheBoundaryAcrossFullAndPartialBlocks() {
        let mask=Array(repeating:Int32(1),count:25)

        #expect(AudioModel.attentionAllows(query:13,key:1,count:mask.count,mask:mask))
        #expect(!AudioModel.attentionAllows(query:13,key:0,count:mask.count,mask:mask))
        #expect(AudioModel.attentionAllows(query:24,key:12,count:mask.count,mask:mask))
        #expect(!AudioModel.attentionAllows(query:24,key:11,count:mask.count,mask:mask))
        #expect(!AudioModel.attentionAllows(query:24,key:25,count:mask.count,mask:mask))
    }
}
