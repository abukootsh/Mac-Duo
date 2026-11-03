import Foundation
import LidSensorKit

/// Prints the lid angle so the sensor can be checked without the app.
///
///     lidprobe          stream the angle until interrupted
///     lidprobe once     print one reading and exit

let sensor = LidSensor()

guard sensor.isAvailable, let precision = sensor.precision else {
    FileHandle.standardError.write(Data("no lid angle sensor found on this Mac\n".utf8))
    exit(1)
}

print("sensor found: \(precision.label)")

if CommandLine.arguments.dropFirst().first == "once" {
    if let angle = sensor.angle() {
        print(String(format: "%.2f°", angle))
        exit(0)
    }
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
var previous: Double?
while true {
    if let angle = sensor.angle(), angle != previous {
        print(String(format: "%7.2f°", angle))
        previous = angle
    }
    usleep(50_000)
}
