const std = @import("std");

pub const QUEUE_SIZE = 32;

/// The position of a key on a keyboard using the qwerty layout. This does not determine the key pressed, just the position on the keyboard.
pub const KeyPosition = enum(u7) {
    ESC,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    PRINT_SCREEN,
    SCROLL_LOCK,
    PAUSE,
    BACKTICK,
    ONE,
    TWO,
    THREE,
    FOUR,
    FIVE,
    SIX,
    SEVEN,
    EIGHT,
    NINE,
    ZERO,
    HYPHEN,
    EQUALS,
    BACKSPACE,
    TAB,
    Q,
    W,
    E,
    R,
    T,
    Y,
    U,
    I,
    O,
    P,
    LEFT_BRACKET,
    RIGHT_BRACKET,
    ENTER,
    CAPS_LOCK,
    A,
    S,
    D,
    F,
    G,
    H,
    J,
    K,
    L,
    SEMICOLON,
    APOSTROPHE,
    HASH,
    LEFT_SHIFT,
    BACKSLASH,
    Z,
    X,
    C,
    V,
    B,
    N,
    M,
    COMMA,
    DOT,
    FORWARD_SLASH,
    RIGHT_SHIFT,
    LEFT_CTRL,
    SPECIAL,
    LEFT_ALT,
    SPACE,
    RIGHT_ALT,
    FN,
    SPECIAL2,
    RIGHT_CTRL,
    INSERT,
    HOME,
    PAGE_UP,
    DELETE,
    END,
    PAGE_DOWN,
    LEFT_ARROW,
    UP_ARROW,
    DOWN_ARROW,
    RIGHT_ARROW,
    NUM_LOCK,
    KEYPAD_SLASH,
    KEYPAD_ASTERISK,
    KEYPAD_MINUS,
    KEYPAD_7,
    KEYPAD_8,
    KEYPAD_9,
    KEYPAD_PLUS,
    KEYPAD_4,
    KEYPAD_5,
    KEYPAD_6,
    KEYPAD_1,
    KEYPAD_2,
    KEYPAD_3,
    KEYPAD_ENTER,
    KEYPAD_0,
    KEYPAD_DOT,
};

pub const KeyboardLights = struct {
    scroll_lock: bool,
    number_lock: bool,
    caps_lock: bool,
};

pub fn KeyPositionToAscii(position: KeyPosition, shift: bool) ?u8 {
    const key: ?u8 = switch (position) {
        .A => 'A',
        .B => 'B',
        .C => 'C',
        .D => 'D',
        .E => 'E',
        .F => 'F',
        .G => 'G',
        .H => 'H',
        .I => 'I',
        .J => 'J',
        .K => 'K',
        .L => 'L',
        .M => 'M',
        .N => 'N',
        .O => 'O',
        .P => 'P',
        .Q => 'Q',
        .R => 'R',
        .S => 'S',
        .T => 'T',
        .U => 'U',
        .V => 'V',
        .W => 'W',
        .X => 'X',
        .Y => 'Y',
        .Z => 'Z',
        .ONE => '1',
        .TWO => '2',
        .THREE => '3',
        .FOUR => '4',
        .FIVE => '5',
        .SIX => '6',
        .SEVEN => '7',
        .EIGHT => '8',
        .NINE => '9',
        .ZERO => '0',
        .ENTER => '\n',
        .SPACE => ' ',
        .LEFT_BRACKET => '[',
        .RIGHT_BRACKET => ']',
        .BACKSLASH => '\\',
        .FORWARD_SLASH => '/',
        .SEMICOLON => ';',
        .APOSTROPHE => '\\',
        .COMMA => ',',
        .DOT => '.',
        else => null,
    };

    if (key) |render_key| {
        if (!shift) {
            return std.ascii.toLower(render_key);
        } else {
            return switch (render_key) {
                '1' => '!',
                '2' => '@',
                '3' => '#',
                '4' => '$',
                '5' => '%',
                '6' => '^',
                '7' => '&',
                '8' => '*',
                '9' => '(',
                '0' => ')',
                '-' => '_',
                '=' => '+',
                '[' => '{',
                ']' => '}',
                '\\' => '|',
                ';' => ':',
                '\'' => '"',
                ',' => '<',
                '.' => '>',
                '/' => '?',
                '`' => '~',
                else => key,
            };
        }
    }

    return key;
}

/// State of modifiers
pub const Modifiers = struct {
    shift: bool,
    control: bool,
    alt: bool,
    super: bool,
};

/// A keyboard action, either a press or release
pub const KeyAction = struct {
    modifiers: Modifiers,
    /// The position of the key
    position: KeyPosition,
    /// Whether it was a release or press
    released: bool,
};

const QueueIndex = std.meta.Int(.unsigned, std.math.log2(QUEUE_SIZE));

pub const Keyboard = struct {
    queue: [QUEUE_SIZE]KeyAction,
    queue_front: QueueIndex,
    queue_end: QueueIndex,
    global_modifiers: Modifiers,

    pub fn init() Keyboard {
        return .{
            .queue = [_]KeyAction{undefined} ** QUEUE_SIZE,
            .queue_front = 0,
            .queue_end = 0,
            .global_modifiers = undefined,
        };
    }

    pub fn isEmpty(self: *const Keyboard) bool {
        return self.queue_end == self.queue_front;
    }

    pub fn isFull(self: *const Keyboard) bool {
        const res = @addWithOverflow(self.queue_end, 1);
        return res[0] == self.queue_front;
    }

    pub fn writeKey(self: *Keyboard, key: KeyAction) bool {
        switch (key.position) {
            .LEFT_SHIFT, .RIGHT_SHIFT => {
                self.global_modifiers.shift = !key.released;
            },
            .LEFT_ALT, .RIGHT_ALT => {
                self.global_modifiers.alt = !key.released;
            },
            else => {},
        }
        if (!self.isFull()) {
            self.queue[self.queue_end] = .{
                .position = key.position,
                .released = key.released,
                .modifiers = self.global_modifiers,
            };
            const res = @addWithOverflow(self.queue_end, 1);
            self.queue_end = res[0];
            return true;
        }

        return false;
    }

    pub fn readKey(self: *Keyboard) ?KeyAction {
        if (self.isEmpty()) return null;

        const key = self.queue[self.queue_front];
        const res = @addWithOverflow(self.queue_front, 1);
        self.queue_front = res[0];
        return key;
    }
};

var keyboard = Keyboard.init();

pub fn getKeyboard(id: usize) ?*Keyboard {
    _ = id;
    return &keyboard;
}
