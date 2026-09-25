import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("redirects", ROOT / "scripts/hawtio-redirects.py")
redirects = importlib.util.module_from_spec(spec)
spec.loader.exec_module(redirects)


class RedirectTests(unittest.TestCase):
    def test_all_cells_grouped_by_shared_client(self):
        report = redirects.inventory(ROOT, ["test", "nonprod", "prod"])
        expected = []
        for environment in ["test", "nonprod", "prod"]:
            expected.extend(redirects.read_yaml(ROOT / "argocd/topology" / f"{environment}.yaml")["workloadCells"])
        clients = report["clients"]
        self.assertEqual(len(clients), 2)
        self.assertEqual(sum(len(client["cells"]) for client in clients), len(expected))
        self.assertEqual({cell["environment"] for cell in clients[0]["cells"]}, {"test", "nonprod"})
        self.assertEqual({uri for client in clients for uri in client["redirectUris"]},
                         {f"https://{cell['managementHost']}/console" for cell in expected})
        self.assertTrue(any(not cell["enabled"] for client in clients for cell in client["cells"]))
        template = redirects.read_yaml(ROOT / "argocd/bootstrap/base/artemis-workloads-applicationset.yaml")
        parameters = template["spec"]["template"]["spec"]["source"]["helm"]["parameters"]
        self.assertEqual(next(p["value"] for p in parameters if p["name"] == "keycloak.redirectUri"),
                         "https://{{.managementHost}}/console")

    def test_reject_placeholder_for_live_preparation(self):
        with self.assertRaisesRegex(ValueError, "placeholder"):
            redirects.inventory(ROOT, ["test"], require_real_hosts=True)

    def test_reject_invalid_hosts_and_duplicates(self):
        for host in ["*.example.com", "example.com/other", "example.com:443", "user@example.com", "-bad.example.com"]:
            with self.subTest(host=host), patch.object(redirects, "read_yaml", side_effect=[
                {"workloadCells": [{"managementHost": host, "workloadCellName": "test"}]},
                {"keycloak": {"issuerUrl": "issuer", "clientId": "client"}},
            ]), self.assertRaisesRegex(ValueError, "invalid managementHost"):
                redirects.inventory(ROOT, ["test"])
        cell = {"managementHost": "console.example.com", "workloadCellName": "test", "enabled": "false"}
        with patch.object(redirects, "read_yaml", side_effect=[
            {"workloadCells": [cell, cell]},
            {"keycloak": {"issuerUrl": "issuer", "clientId": "client"}},
        ]), self.assertRaisesRegex(ValueError, "duplicate"):
            redirects.inventory(ROOT, ["test"])


if __name__ == "__main__":
    unittest.main()
