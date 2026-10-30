# Third-party material in BoardVision

`Sources/BoardVision/Resources/PieceNet.bin` holds the weights of a small CNN trained on synthetic square images
rendered from the piece sets below (rendering code: `mac/Tools/TrainBoardModel`). Only the trained weights are
shipped; no artwork is included in the library. The test fixtures in `Tests/BoardVisionTests/Fixtures/HeldOutPieces`
are PNG renderings of the held-out piece set (chessnut).

Piece sets come from the [lichess `lila` repository](https://github.com/lichess-org/lila) (`public/piece/*`,
licenses as listed in lila's `COPYING.md`):

| Set | Author | License | Role |
| --- | --- | --- | --- |
| cburnett | Colin M.L. Burnett | GPLv2+ | training |
| merida | Armando Hernandez Marroquin | GPLv2+ | training |
| mpchess | Maxime Chupin | GPLv3+ | training |
| pirouetti | pirouetti | AGPLv3+ | training |
| letter | usolando | AGPLv3+ | training |
| pixel | therealqtpi | AGPLv3+ | training |
| shapes | flugsio | CC BY-SA 4.0 | training |
| rhosgfx | RhosGFX | CC0 1.0 | training |
| fantasy, spatial, celtic | Maurizio Monge (chess-art) | MIT | training |
| kiwen-suwi | neverRare | CC BY 4.0 | training |
| firi | James Faure (Firi-pieceset) | CC BY 4.0 | training |
| totoy | Kosal Sen | CC BY 4.0 | training |
| papercut | Nikolay Anzarov | CC BY 4.0 | training |
| chessnut | Alexis Luengas | Apache 2.0 | held out (evaluation and tests only) |

Deliberately not used because their licenses are non-commercial / non-derivative / unclear: alpha, chess7, companion,
leipzig, the sadsnake1 sets (staunty, fresca, ...), california, caliente, maestro, anarcandy, cooke, monarchy, xkcd,
shahi-ivory-brown, and sets lila lists without a license (horsey, riohacha, reillycraig, kosal, governor).
The `cm-chessboard@8.7.0` npm package was fetched but its `standard.svg` is the same cburnett artwork already covered
above, and its `staunty` sprite is a sadsnake1 set (CC BY-NC-SA), so nothing from it is used.

Board themes (colours) are original/simple colour pairs inspired by common site themes; no site assets are used.
