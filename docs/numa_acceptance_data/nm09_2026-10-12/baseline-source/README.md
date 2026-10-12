# Source nguyên trạng từ compiler cache NM-03

Được sao chép từ `/build` của `battleship-benchmark-build:nm03`, image ID
`sha256:44fe653d66ba84c8b64d4aa91bafb1067490d5d4ce4ba197335a32716a816c00` (ID đầy đủ được ghi trong evidence NM-09), ngày 2026-10-12.
Đối chiếu manifest NM-03: **24/25 file khớp SHA-256**; toàn bộ Haskell/build
inputs được liệt kê khớp. Một file **không khớp**:

- `scripts/benchmark-runtime.mjs`: bản cache hash
  `d9473b16ed3bd37badd1a085736cf46462d755cbdb49bc5ffeaba02d8e1162d4`;
  manifest khi đo ghi `5a06ebcefb868f70831268d4368ee83d3328da35b4ea42942cd22bdec4e3dabd`.
- File được giữ nguyên, không dựng lại để vượt kiểm tra hash. Bản cache CLI
  không hỗ trợ tách `--key=value`; setup bridge port0 còn lỗi. Không dùng
  script cache này để chạy lại toàn bộ loạt; log smoke lỗi được giữ trong evidence.

Snapshot **không phải exact historical harness**. Dữ liệu/manifest gốc NM-03
không bị sửa. `../snapshot.json` liệt kê expected/actual từng file.
`../prepare-baseline.py` dùng Git nền94a7aaa cho module/test phụ trợ, overlay
snapshot đã kiểm tra vào context mới và tạo runner re-measure riêng từ mã
hiện tại, với hash và nhãn riêng. Đây là phương án dựng lại source game
để đo lại có nhãn giới hạn, không phải khẳng định build/binary/timing bitwise
giống lượt đo cũ. Xem [NM-09](../../../numa_acceptance.md) mục11.
