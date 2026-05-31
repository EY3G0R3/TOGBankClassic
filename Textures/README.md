# Textures

Custom textures shipped with TOGBankClassic.

## broom.tga — Cancel-Stale button icon (BROOM-001)

Classic Era's client ships no broom icon (`INV_Broom_01`, `INV_Misc_Broom_01`,
and `INV_Pet_Broom` all render as the blue missing-texture box), so the
Cancel-Stale button in the Requests window uses this bundled texture instead.

Requirements:

- **Format:** 32-bit TGA (uncompressed), with an alpha channel. Not PNG.
- **Dimensions:** power of two — 64×64 (matches Blizzard icon size).
- **Transparency:** alpha around the broom so the button isn't a square tile.

Referenced from `Modules/UI/Requests.lua` as
`Interface\AddOns\TOGBankClassic\Textures\broom` (no extension needed).
