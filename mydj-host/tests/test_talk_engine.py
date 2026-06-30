from __future__ import annotations

import sys
import unittest
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_DIR))

from models.schemas import TrackInfo  # noqa: E402
import services.program_memory as program_memory  # noqa: E402
import services.prompt_builder as prompt_builder  # noqa: E402
import services.talk_engine as talk_engine  # noqa: E402


class TalkEngineTest(unittest.TestCase):
    def test_postprocess_removes_closing_language(self) -> None:
        text = talk_engine.postprocess_talk_text("That wraps it up, until next time")
        self.assertEqual(text, "Here comes the next track.")

    def test_postprocess_adds_sentence_punctuation(self) -> None:
        text = talk_engine.postprocess_talk_text("Coming up next is a bright one")
        self.assertEqual(text, "Coming up next is a bright one.")

    def test_postprocess_removes_unsupported_tts_tags(self) -> None:
        text = talk_engine.postprocess_talk_text("Tiny studio update [excited]: coffee survived.")
        self.assertEqual(text, "Tiny studio update: coffee survived.")

    def test_postprocess_keeps_supported_tts_tags(self) -> None:
        text = talk_engine.postprocess_talk_text("That one woke up the mixer. [Laugh]")
        self.assertEqual(text, "That one woke up the mixer. [laugh].")

    def test_clamp_talk_length_prefers_sentence_boundary(self) -> None:
        source = "First sentence. " + ("Second sentence is too long " * 20)
        text = talk_engine.clamp_talk_length(source, "short")
        self.assertLessEqual(len(text), 180)
        self.assertTrue(text.endswith("."))


class ProgramMemoryTest(unittest.TestCase):
    def test_prompt_guidance_mentions_recent_talk(self) -> None:
        program_memory.remember_talk(
            text="A clean little radio break for the afternoon.",
            next_track=TrackInfo(title="Next", artist="Artist"),
            previous_track=TrackInfo(title="Prev", artist="Artist"),
        )

        guidance = program_memory.prompt_guidance()

        self.assertIn("PROGRAM MEMORY", guidance)
        self.assertIn("radio break", guidance)


class PromptBuilderTest(unittest.TestCase):
    def test_prompt_encourages_off_topic_airbreaks(self) -> None:
        prompt = prompt_builder._build(
            context="[Optional live context, use rarely: afternoon]",
            pcfg={
                "persona": "a radio DJ",
                "style": "Loose and funny.",
                "joke_rate": 1.0,
                "emotions": "(laugh)",
            },
            lcfg=prompt_builder._get_language_config("en"),
            next_track=TrackInfo(title="Next", artist="Artist"),
            previous_track=TrackInfo(title="Prev", artist="Artist"),
            length_instruction="Keep it short.",
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

        self.assertIn("Off-topic is okay in small doses", prompt)
        self.assertIn("SELECTED AIRBREAK BIT", prompt)
        self.assertIn("Do not make every talk a song review", prompt)
        self.assertIn("Never default to 'perfect weather/time for music'", prompt)


class TalkLengthTest(unittest.TestCase):
    def _make_prompt(self, talk_length: str) -> str:
        pcfg = prompt_builder._get_personality("standard")
        return prompt_builder._build(
            context="[Optional live context, use rarely: evening]",
            pcfg=pcfg,
            lcfg=prompt_builder._get_language_config("en"),
            next_track=TrackInfo(title="Night Owl", artist="Chromatics"),
            previous_track=TrackInfo(title="Drive", artist="Chromatics"),
            length_instruction=prompt_builder._LENGTH_INSTRUCTIONS[talk_length],
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

    def test_short_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("short")
        self.assertIn("18–30 words", prompt)

    def test_medium_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("medium")
        self.assertIn("35–60 words", prompt)

    def test_long_length_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("long")
        self.assertIn("70–100 words", prompt)

    def test_clamp_short_at_180_chars(self) -> None:
        long_text = "Word " * 60
        clamped = talk_engine.clamp_talk_length(long_text, "short")
        self.assertLessEqual(len(clamped), 180)

    def test_clamp_long_at_800_chars(self) -> None:
        long_text = "Word " * 200
        clamped = talk_engine.clamp_talk_length(long_text, "long")
        self.assertLessEqual(len(clamped), 800)


class PersonalityTest(unittest.TestCase):
    def _make_prompt(self, personality: str) -> str:
        pcfg = prompt_builder._get_personality(personality)
        return prompt_builder._build(
            context="[Optional live context, use rarely: night]",
            pcfg=pcfg,
            lcfg=prompt_builder._get_language_config("en"),
            next_track=TrackInfo(title="Blue Monday", artist="New Order"),
            previous_track=None,
            length_instruction=prompt_builder._LENGTH_INSTRUCTIONS["medium"],
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

    def test_comedian_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("comedian")
        self.assertIn("funny music radio DJ", prompt)
        self.assertIn("The track intro is still the payoff", prompt)

    def test_intellectual_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("intellectual")
        self.assertIn("thoughtful music radio DJ", prompt)

    def test_energetic_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("energetic")
        self.assertIn("upbeat drive-time", prompt)

    def test_chill_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("chill")
        self.assertIn("mellow late-night", prompt)

    def test_standard_persona_in_prompt(self) -> None:
        prompt = self._make_prompt("standard")
        self.assertIn("warm music radio DJ", prompt)

    def test_unknown_personality_falls_back_to_standard(self) -> None:
        pcfg = prompt_builder._get_personality("nonexistent")
        self.assertEqual(pcfg["persona"], prompt_builder._PERSONALITIES["standard"]["persona"])

    def test_each_personality_has_house_rules(self) -> None:
        for name, cfg in prompt_builder._PERSONALITIES.items():
            self.assertIn("house_rules", cfg, f"Missing house_rules for personality: {name}")
            self.assertTrue(cfg["house_rules"].strip(), f"Empty house_rules for personality: {name}")

    def test_each_personality_uses_only_supported_tts_tags(self) -> None:
        supported = {"[sigh]", "[gasp]", "[cough]", "[laugh]", "[whisper]", "[breath]"}
        for name, cfg in prompt_builder._PERSONALITIES.items():
            tags = [
                token.strip()
                for token in cfg["emotions"].splitlines()
                if token.strip()
            ]
            self.assertTrue(tags, f"No TTS tags for personality: {name}")
            for tag in tags:
                self.assertIn(tag, supported, f"Unsupported TTS tag for {name}: {tag}")

    def test_album_included_in_track_label(self) -> None:
        track = TrackInfo(title="Karma Police", artist="Radiohead", album="OK Computer")
        label = prompt_builder._track_label(track)
        self.assertIn("OK Computer", label)

    def test_album_omitted_when_none(self) -> None:
        track = TrackInfo(title="Karma Police", artist="Radiohead")
        label = prompt_builder._track_label(track)
        self.assertNotIn("from", label)


class LanguageTest(unittest.TestCase):
    def _make_prompt(self, language: str) -> str:
        pcfg = prompt_builder._get_personality("standard")
        lcfg = prompt_builder._get_language_config(language)
        return prompt_builder._build(
            context="[Optional live context, use rarely: night]",
            pcfg=pcfg,
            lcfg=lcfg,
            next_track=TrackInfo(title="Blue Monday", artist="New Order"),
            previous_track=None,
            length_instruction=prompt_builder._LENGTH_INSTRUCTIONS["medium"],
            is_mid_song=False,
            username=None,
            dj_name=None,
            custom_prompt=None,
            track_history=None,
        )

    def test_english_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("en")
        self.assertIn("English", prompt)

    def test_japanese_instruction_in_prompt(self) -> None:
        prompt = self._make_prompt("ja")
        self.assertIn("日本語", prompt)
        self.assertIn("Japanese", prompt)

    def test_unknown_language_falls_back_to_english(self) -> None:
        lcfg = prompt_builder._get_language_config("xx")
        self.assertEqual(lcfg, prompt_builder._LANGUAGE_CONFIG["en"])

    def test_all_supported_languages_have_required_keys(self) -> None:
        for lang, cfg in prompt_builder._LANGUAGE_CONFIG.items():
            self.assertIn("output_instruction", cfg, f"Missing output_instruction for: {lang}")
            self.assertTrue(cfg["output_instruction"].strip(), f"Empty output_instruction for: {lang}")

    def test_language_config_priority_prefers_argument_over_config(self) -> None:
        import asyncio
        track = TrackInfo(title="Song", artist="Artist")
        cfg = {"dj": {"default_language": "en"}}
        prompt = asyncio.run(
            prompt_builder.build_prompt(
                next_track=track,
                previous_track=None,
                talk_length="medium",
                cfg=cfg,
                language="ja",
            )
        )
        self.assertIn("日本語", prompt)


if __name__ == "__main__":
    unittest.main()
