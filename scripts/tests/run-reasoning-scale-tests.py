#!/usr/bin/env python3
from pathlib import Path
import subprocess,tempfile
r=Path(__file__).resolve().parents[2]
s=(r/'ios/ZCodeMobile/Core/Models.swift').read_text();s=s[s.index('enum ReasoningScale {'):s.index('enum ReasoningLevel:')]
checks='''
precondition(ReasoningScale.index(location: 100, width: 300, count: 0) == nil)
precondition(ReasoningScale.index(location: .nan, width: 300, count: 8) == nil)
precondition(ReasoningScale.index(location: 100, width: .infinity, count: 8) == nil)
precondition(ReasoningScale.index(location: -100, width: 300, count: 8) == 0)
precondition(ReasoningScale.index(location: 9999, width: 300, count: 8) == 7)
precondition(ReasoningScale.index(location: 100, width: 0, count: 1) == 0)
for count in 1...20 {
 for x in stride(from: -100.0, through: 1000.0, by: 0.5) {
  let i = ReasoningScale.index(location: x, width: 260, count: count)!
  precondition((0..<count).contains(i))
 }
}
for count in 1...20 {
 let levels = (0..<count).map { "level-\($0)" }
 for index in levels.indices {
  let angle = ReasoningScale.angle(value: levels[index], levels: levels)
  precondition(abs(angle - (-120 + 240 * Double(index + 1) / Double(count))) < 0.00001)
 }
 precondition(ReasoningScale.angle(value: levels.last!, levels: levels) == 120)
}
precondition(ReasoningScale.angle(value: "unknown", levels: []) == -120)
print("6 drag boundaries, 44020 drag samples, and 231 dynamic dial checks passed")
'''
with tempfile.TemporaryDirectory() as d:
 p=Path(d)/'main.swift';p.write_text(s+checks)
 sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
 subprocess.run(['xcrun','--sdk','macosx','swiftc','-sdk',sdk,str(p),'-o',d+'/test'],check=True)
 subprocess.run([d+'/test'],check=True)
