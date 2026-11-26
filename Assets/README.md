# Default art

Five clips, one per state, played by `Sources/PetView.swift` instead of the drawn cat.

They come from [dsh-pet](https://github.com/PC2005-cloud/dsh-pet) (MIT, © PC2005-cloud): that project
generates its browser pet with an AI video model, keys the green out, and ships the result as
VP9-alpha webm. `tools/make-pet.sh` converts one to the HEVC-alpha `.mov` macOS plays natively.

| File | Source clip (`dsh-pet/assets/webm/`) |
| --- | --- |
| `idle.mov` | 待机呼吸休闲 |
| `working.mov` | 工作状态-忙碌点按 |
| `blocked.mov` | 用鲸鱼尾巴拍打地面 |
| `done.mov` | 工作状态-雀跃庆祝 |
| `error.mov` | 工作状态-垂头叹气冒汗 |

Delete this directory (or a single file) and the app falls back to the cat drawn in
`Sources/CatSprite.swift` for that state.
