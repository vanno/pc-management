import unittest

from pcm import majwin, pilot
from pcm.meshctrl import MeshError
from test_pilot import FakeMesh, nonces, pilot_script

KB = "1a2b3c4d-0000-4000-8000-000000000001"
GPU = "1a2b3c4d-0000-4000-8000-000000000002"


def survey_reply(windows=(), logiciels=(), **extra):
    return {"ok": True, "detail": "", "windows_ok": True, "windows": list(windows), "logiciels": list(logiciels), "redemarrage_attendu": False, **extra}


class ParamsTests(unittest.TestCase):
    def test_refusals_never_reach_the_device(self):
        for params in (
            {"op": "tout"},
            {"op": "appliquer"},
            {"op": "appliquer", "windows": [{"id": "pas-un-guid"}]},
            {"op": "appliquer", "logiciels": [{"id": "Video LAN"}]},
            {"op": "appliquer", "logiciels": [{"id": "VideoLAN.VLC", "version": "3.0; rm"}]},
        ):
            mesh = FakeMesh({})
            ok, text, controle, data = majwin.apply(mesh, "node//x", params, [], nonces(), sleep=lambda s: None)
            self.assertFalse(ok, params)
            self.assertEqual(mesh.calls, [], params)

    def test_versions_are_frozen(self):
        req = majwin.parse({"op": "appliquer", "windows": [{"id": KB.upper(), "rev": 201, "titre": "KB5050"}], "logiciels": [{"id": "VideoLAN.VLC", "version": "3.0.21"}]})
        self.assertEqual(req["windows"], [{"id": KB, "rev": 201, "titre": "KB5050", "kb": ""}])
        self.assertEqual(req["logiciels"], [{"id": "VideoLAN.VLC", "version": "3.0.21"}])
        self.assertTrue(req["redemarrer"])


class SurveyTests(unittest.TestCase):
    def test_survey_sends_catalogue_and_summarises(self):
        mesh = FakeMesh({"releve": [survey_reply(
            [{"id": KB, "genre": "securite"}, {"id": GPU, "genre": "pilote", "gpu": True}],
            [{"id": "VideoLAN.VLC", "installe": "3.0.20", "disponible": "3.0.21"}, {"id": "Zoom.Zoom", "installe": "6.2", "disponible": None}],
        )]})
        ok, text, data = majwin.survey(mesh, "node//x", ["VideoLAN.VLC", "Zoom.Zoom", "pas bon"], nonces())
        self.assertTrue(ok)
        self.assertEqual(mesh.calls[0][0]["logiciels"], ["VideoLAN.VLC", "Zoom.Zoom"])
        self.assertEqual(mesh.calls[0][1], majwin.SURVEY_TIMEOUT)
        self.assertIn("2 mises à jour Windows (1 de sécurité, 1 pilote dont 1 carte graphique)", text)
        self.assertIn("1 logiciel à mettre à jour", text)
        self.assertEqual(len(data["windows"]), 2)

    def test_script_is_majwin(self):
        captured = []

        class Mesh(FakeMesh):
            def run_powershell(self, device_id, command, timeout=None):
                captured.append(pilot_script(command))
                return super().run_powershell(device_id, command, timeout)

        majwin.survey(Mesh({"releve": [survey_reply()]}), "node//x", [], nonces())
        self.assertIn("PointeNoire-MiseAJour", captured[0])
        self.assertLess(len(pilot.build_command({"op": "releve"}, "ab", majwin.SCRIPT.read_text(encoding="utf-8"))), pilot.MAX_COMMAND)


class ApplyTests(unittest.TestCase):
    PARAMS = {"op": "appliquer", "windows": [{"id": KB, "titre": "KB5050"}], "logiciels": [{"id": "VideoLAN.VLC", "version": "3.0.21"}]}

    def done(self, **etat):
        base = {"etape": "termine", "fin": "2026-11-06T10:00:00.0000000Z", "detail": "2 posée(s), 0 en échec", "redemarre": False,
                "elements": [{"genre": "windows", "id": KB, "etat": "installee"}, {"genre": "logiciel", "id": "VideoLAN.VLC", "etat": "installee"}]}
        base.update(etat)
        return {"ok": True, "etat": base, "demarre_le": "2026-11-06T08:00:00.0000000Z"}

    def test_follows_reboot_then_checks(self):
        mesh = FakeMesh({
            "appliquer": [{"ok": True, "detail": "lancée"}],
            "resultat": [
                {"ok": True, "etat": {"etape": "en_cours", "detail": "installation"}},
                self.done(redemarre=True),
                MeshError("hors ligne"),
                {**self.done(redemarre=True), "demarre_le": "2026-11-06T10:03:00.0000000Z"},
            ],
            "releve": [survey_reply([], [{"id": "VideoLAN.VLC", "installe": "3.0.21"}])],
        })
        ok, text, controle, data = majwin.apply(mesh, "node//x", self.PARAMS, ["VideoLAN.VLC"], nonces(), sleep=lambda s: None)
        self.assertTrue(ok, text)
        self.assertEqual(controle["etat"], "verifie")
        self.assertEqual([c[0]["op"] for c in mesh.calls], ["appliquer", "resultat", "resultat", "resultat", "resultat", "releve"])

    def test_update_still_offered_is_not_applied(self):
        mesh = FakeMesh({
            "appliquer": [{"ok": True}],
            "resultat": [self.done()],
            "releve": [survey_reply([{"id": KB}], [{"id": "VideoLAN.VLC", "installe": "3.0.20", "disponible": "3.0.21"}])],
        })
        ok, text, controle, data = majwin.apply(mesh, "node//x", self.PARAMS, [], nonces(), sleep=lambda s: None)
        self.assertFalse(ok)
        self.assertEqual(controle["etat"], "pas_applique")
        self.assertIn("3.0.20 au lieu de 3.0.21", text)

    def test_event_mode_on_device(self):
        mesh = FakeMesh({"appliquer": [{"ok": False, "detail": "refusé : le poste est en mode événement"}]})
        ok, text, controle, data = majwin.apply(mesh, "node//x", self.PARAMS, [], nonces(), sleep=lambda s: None)
        self.assertFalse(ok)
        self.assertIn("mode événement", text)

    def test_gives_up_after_limit(self):
        clock = iter(range(0, 100_000, 3600))
        mesh = FakeMesh({"appliquer": [{"ok": True}], "resultat": [MeshError("hors ligne")] * 5})
        ok, text, controle, data = majwin.apply(mesh, "node//x", self.PARAMS, [], nonces(), sleep=lambda s: None, clock=lambda: next(clock))
        self.assertFalse(ok)
        self.assertIn("sans fin", text)


class AgentScriptTests(unittest.TestCase):
    def test_guards(self):
        text = majwin.SCRIPT.read_text(encoding="utf-8")
        # Jamais de mise à jour de fonctionnalité, jamais en mode événement.
        self.assertIn("if ($genre -eq 'fonction') { continue }", text)
        self.assertGreaterEqual(text.count("Test-Evenement"), 5)
        # Le script recopié pour la tâche planifiée est lu avec son BOM.
        self.assertIn("Write-Utf8 $fichierScript $src $true", text)


if __name__ == "__main__":
    unittest.main()


class DeferTests(unittest.TestCase):
    def test_defer_is_checked(self):
        mesh = FakeMesh({"report": [{"ok": True, "detail": "stratégie de report : 7 jours derrière le pilote", "points": [{"nom": "Report des correctifs", "ok": True, "constat": "7 jour(s)"}]}]})
        ok, text, controle = majwin.defer(mesh, "node//x", {"op": "report", "jours": 7}, nonces())
        self.assertTrue(ok)
        self.assertEqual(mesh.calls[0][0], {"op": "report", "jours": 7})
        self.assertEqual(controle["etat"], "verifie")

    def test_weekly_renewal_sends_no_days(self):
        mesh = FakeMesh({"report": [{"ok": True, "detail": "aucun report demandé sur ce poste", "points": []}]})
        ok, text, controle = majwin.defer(mesh, "node//x", {"op": "report", "planifie": True}, nonces())
        self.assertTrue(ok)
        self.assertEqual(mesh.calls[0][0], {"op": "report"})
        self.assertIsNone(controle)

    def test_bad_days_never_reach_device(self):
        for jours in (-1, 31, "7", True):
            mesh = FakeMesh({})
            ok, _, _ = majwin.defer(mesh, "node//x", {"op": "report", "jours": jours}, nonces())
            self.assertFalse(ok, jours)
            self.assertEqual(mesh.calls, [])

    def test_kb_match_counts_as_still_offered(self):
        req = majwin.parse({"op": "appliquer", "windows": [{"id": KB, "kb": "KB5050"}]})
        after = {"windows_ok": True, "windows": [{"id": GPU, "kb": "KB5050"}], "logiciels": []}
        self.assertEqual(majwin.check(req, after, [])["etat"], "pas_applique")
