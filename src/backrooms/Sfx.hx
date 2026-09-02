// Embedded sounds (CONTRACT §2). fp class. Paths are relative to src/backrooms/.
// Complete: all() instantiates each once in AudioBus id order.
// The mp3 files are produced by tools/backrooms_sfx.py (assets unit); every file listed here must exist at compile time.
@:sound("../../www/games/backrooms/sfx/hum.mp3") class SndHum extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hum_low.mp3") class SndHumLow extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hum_dark.mp3") class SndHumDark extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/drone.mp3") class SndDrone extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/presence.mp3") class SndPresenceLo extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/presence_hi.mp3") class SndPresenceHi extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/drip_loop.mp3") class SndDrip extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/step1.mp3") class SndStep1 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/step2.mp3") class SndStep2 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/step3.mp3") class SndStep3 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/step4.mp3") class SndStep4 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/splash1.mp3") class SndSplash1 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/splash2.mp3") class SndSplash2 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/distant1.mp3") class SndDistant1 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/distant2.mp3") class SndDistant2 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/distant3.mp3") class SndDistant3 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/distant4.mp3") class SndDistant4 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/thud.mp3") class SndDistant5 extends flash.media.Sound {}      // distant5 = thud.mp3
@:sound("../../www/games/backrooms/sfx/distant6.mp3") class SndDistant6 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/clicks1.mp3") class SndClicks1 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/clicks2.mp3") class SndClicks2 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/howl1.mp3") class SndHowl1 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/howl2.mp3") class SndHowl2 extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/snarl.mp3") class SndSnarl extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/hound_step.mp3") class SndHoundStep extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/screech.mp3") class SndScream extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/static.mp3") class SndStatic extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/tape.mp3") class SndTape extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/vcr_whirr.mp3") class SndVcr extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/flicker.mp3") class SndFlicker extends flash.media.Sound {}
@:sound("../../www/games/backrooms/sfx/paper.mp3") class SndPaper extends flash.media.Sound {}

class Sfx {
    // instantiates each once, in AudioBus id order
    public static function all():Array<flash.media.Sound> {
        return [
            new SndHum(), new SndHumLow(), new SndHumDark(), new SndDrone(),                 // 0..3
            new SndPresenceLo(), new SndPresenceHi(), new SndDrip(),                          // 4..6
            new SndStep1(), new SndStep2(), new SndStep3(), new SndStep4(),                   // 7..10
            new SndSplash1(), new SndSplash2(),                                               // 11..12
            new SndDistant1(), new SndDistant2(), new SndDistant3(), new SndDistant4(), new SndDistant5(), new SndDistant6(), // 13..18
            new SndClicks1(), new SndClicks2(),                                               // 19..20
            new SndHowl1(), new SndHowl2(),                                                   // 21..22
            new SndSnarl(), new SndHoundStep(), new SndScream(),                              // 23..25
            new SndStatic(), new SndTape(), new SndVcr(), new SndFlicker(), new SndPaper()    // 26..30
        ];
    }
}
