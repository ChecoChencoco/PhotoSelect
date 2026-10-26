import Foundation
import ProbeCore

func fixture(bigEndian: Bool = false, orientation: Int = 6) -> Data {
    var data = Data(bigEndian ? [77,77] : [73,73])
    func add(_ value: Int, _ size: Int) {
        for i in 0..<size { data.append(UInt8((value >> (8*(bigEndian ? size-1-i : i))) & 255)) }
    }
    add(42,2); add(8,4); add(4,2)
    for (tag,type,value) in [(274,3,orientation),(513,4,62),(514,4,4),(330,4,66)] {
        add(tag,2); add(type,2); add(1,4); add(value,type == 3 ? 2 : 4)
        if type == 3 { add(0,2) }
    }
    add(0,4); data.append(contentsOf:[255,216,255,217])
    add(3,2)
    for (tag,value) in [(256,8000),(257,5320),(262,32803)] {
        add(tag,2); add(4,2); add(1,4); add(value,4)
    }
    add(0,4); return data
}
var passed=0,failed=0
@MainActor func check(_ name: String, _ action: () throws -> Bool) {
    do {
        if try action() { passed+=1; print("PASS \(name)") }
        else { failed+=1; print("FAIL \(name)") }
    } catch { failed+=1; print("FAIL \(name): \(error)") }
}
func throwsError(_ action: () throws -> Void) -> Bool {
    do { try action(); return false } catch { return true }
}
for big in [false,true] {
    check("\(big ? "big" : "little") endian, Orientation 6 and RAW SubIFD") {
        let tiff=try TIFFContainer(data:fixture(bigEndian:big))
        let jpeg=try tiff.embeddedJPEGs()
        return tiff.orientation == 6 && tiff.rawDirectory?.tags[256]?.first == 8000 &&
            tiff.rawDirectory?.tags[257]?.first == 5320 &&
            jpeg == [Data([255,216,255,217])]
    }
}
check("Every truncation rejected without crash") {
    let data=fixture()
    return (0..<data.count).allSatisfy { n in throwsError { _=try TIFFContainer(data:Data(data.prefix(n))) } }
}
check("Cyclic IFD rejected") {
    var data=fixture(); data.replaceSubrange(54..<58,with:[8,0,0,0])
    return throwsError { _=try TIFFContainer(data:data) }
}
check("JPEG range overflow rejected") {
    var data=fixture(); data.replaceSubrange(42..<46,with:[255,255,255,127])
    let parsed=try TIFFContainer(data:data)
    return throwsError { _=try parsed.embeddedJPEGs() }
}
check("JPEG markers validated") {
    var data=fixture(); data[62]=0
    return throwsError { _=try TIFFContainer(data:data).embeddedJPEGs() }
}
check("Non-TIFF rejected") { throwsError { _=try TIFFContainer(data:Data("not a TIFF file".utf8)) } }
check("Excessive value count rejected") {
    var data=fixture(); data.replaceSubrange(14..<18,with:[255,255,255,127])
    return throwsError { _=try TIFFContainer(data:data) }
}
print("Result: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
