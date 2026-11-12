// Generated from design/system/tokens.json by scripts/design/gen_tokens.py. Do not edit.
// The rules for each value are in design/system/README.md. Colors are not here: they come from
// the picked palette at run time (Theme, Look.swift); gen_tokens.py checks the default one.
import CoreGraphics

/// The design tokens. New code uses DS.* for sizes and Theme.* for colors and fonts.
enum DS {
    /// Paddings and stack spacings.
    enum Space {
        /// Tag vertical padding; hairline gaps. 78 paddings, 96 spacings.
        static let s2: CGFloat = 2
        /// BracketButton vertical padding, rail icon stack, label-to-icon. 120 paddings, 121 spacings.
        static let s4: CGFloat = 4
        /// Tight rows, chart legend gaps. 121 paddings, 230 spacings.
        static let s6: CGFloat = 6
        /// BracketButton and Tag horizontal padding, the page panel's gap to the window edge, tile label gap. 167 paddings, 268 spacings.
        static let s8: CGFloat = 8
        /// Tooltip and row padding. 193 paddings (the most used), 245 spacings.
        static let s10: CGFloat = 10
        /// Default card padding (.card), Settings group inner gap. 162 paddings, 147 spacings.
        static let s12: CGFloat = 12
        /// Tile grids (Settings mode/theme tiles). 108 paddings, 105 spacings.
        static let s14: CGFloat = 14
        /// AccentButtonStyle horizontal padding; grid row gaps. 96 paddings, 38 spacings.
        static let s16: CGFloat = 16
        /// Section padding inside boards. 46 paddings, 9 spacings.
        static let s20: CGFloat = 20
        /// Between page sections. 45 paddings, 13 spacings.
        static let s24: CGFloat = 24
        /// Page vertical padding (Settings pages). 49 paddings, 8 spacings.
        static let s28: CGFloat = 28
        /// Page horizontal padding (Settings pages); the blur room inside a card's shadow bitmap. 10 paddings.
        static let s32: CGFloat = 32
    }

    /// Corner radii. Draw them with style: .continuous. pill is a Capsule().
    enum Radius {
        /// Small marks: progress bars, chips inside a tile, the 3px inset around a picked tile. 21 uses; 1-2 and 4 map here.
        static let r3: CGFloat = 3
        /// Thumbnails in rows, small wells. 28 uses; 5 maps here.
        static let r6: CGFloat = 6
        /// Text fields (TakesConfirm), small buttons, menu-row highlight (today 7). 80 uses; 7 maps here.
        static let r8: CGFloat = 8
        /// Tooltips (ChartKit), the ⌘F find bar, tile previews. 79 uses; 9 (BracketButton, RailButton, TakesSwitch) maps here.
        static let r10: CGFloat = 10
        /// Theme.radius: cards' default, the page panel (pagePanel), menus and panels (menuChrome). 101 + 28 Theme.radius uses; 11 maps here.
        static let r12: CGFloat = 12
        /// Larger panels and media tiles. 52 uses; 13 maps here (the picked-tile ring is 13 = 10 + 3 inset).
        static let r14: CGFloat = 14
        /// Paper cards that float on the canvas (.card). 35 uses; 18-40 map here unless the shape is a pill.
        static let r16: CGFloat = 16
        /// Capsule(): buttons (AccentButtonStyle), Tag, the find field, badges. 288 Capsule uses.
        static let pill: CGFloat = 999
        /// radius-12.
        static let panel: CGFloat = r12
        /// radius-16.
        static let card: CGFloat = r16
    }

    /// Font sizes for Theme.sans and Theme.mono. The display sizes are the size you pass to
    /// Theme.display (it draws them at x 0.8, which is the token's px).
    enum FontSize {
        /// Tiny meta and badge counts. Today 10.5 (55 sans + 59 mono); 8-10 map here.
        static let xxs: CGFloat = 10.5
        /// SectionLabel, notes, blurbs. The most used small size (285 sans); 11 maps here.
        static let xs: CGFloat = 11.5
        /// Small controls and list meta (336 sans, the most used size).
        static let sm: CGFloat = 12
        /// BracketButton, menu child rows, help text (304 sans).
        static let md: CGFloat = 12.5
        /// Body: Theme.body, menu rows, buttons (210 sans).
        static let body: CGFloat = 13
        /// Board titles in the top row; 13.5 and 14.5 map here.
        static let lg: CGFloat = 14
        /// Lead lines in empty states; 15 and 15.5 map here.
        static let xl: CGFloat = 16
        /// fs-d-sm: 16.8 px drawn. Display 21 rendered (21 x 0.8).
        static let displaySm: CGFloat = 21
        /// fs-d-md: 17.6 px drawn. Display 22 rendered: chat intro titles (22 uses, the most used display size).
        static let displayMd: CGFloat = 22
        /// fs-d-lg: 20.8 px drawn. Display 26 rendered: page titles.
        static let displayLg: CGFloat = 26
        /// fs-d-xl: 25.6 px drawn. Display 32 rendered: big numbers and hero titles.
        static let displayXl: CGFloat = 32
    }
}
