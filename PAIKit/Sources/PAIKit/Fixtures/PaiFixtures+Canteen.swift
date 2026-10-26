import Foundation

/// `GET /api/canteen/entries`: one parsed menu with both diet kinds, and one mail whose PDFs did
/// not parse, so the screen photographs a menu and an error line.
extension PaiFixtures {

    public static let canteenEntries = #"""
        {
          "entries": [
            {
              "id": "c4a7e1f0-0000-4c1a-8f30-2b7e5c918d81",
              "received_at": "2026-08-31T07:45:00.123456+00:00",
              "link": "https://forms.example.invalid/order",
              "attachments": [
                {
                  "id": "a1", "filename": "Speiseplan_KW36_de.pdf", "content_type": "application/pdf",
                  "size": 183204, "language": "de"
                },
                {
                  "id": "a2", "filename": "Menu_KW36_en.pdf", "content_type": "application/pdf",
                  "size": 181992, "language": "en"
                }
              ],
              "menu": {
                "days": [
                  {
                    "date": "2026-09-07", "label_de": "Montag", "label_en": "Monday",
                    "meals": [
                      {
                        "number": 1, "kind": "vegan", "name_de": "Linsen-Dal mit Reis",
                        "name_en": "Lentil dal with rice", "ingredients_de": ["Linsen", "Kokosmilch", "Reis"],
                        "ingredients_en": ["Lentils", "Coconut milk", "Rice"], "milk": null, "egg": null
                      },
                      {
                        "number": 3, "kind": "vegetarian", "name_de": "Spinatlasagne",
                        "name_en": "Spinach lasagne", "ingredients_de": ["Spinat", "Nudelteig", "Käse"],
                        "ingredients_en": ["Spinach", "Pasta sheets", "Cheese"], "milk": true, "egg": true
                      }
                    ]
                  },
                  {
                    "date": "2026-09-08", "label_de": "Dienstag", "label_en": "Tuesday",
                    "meals": [
                      {
                        "number": 2, "kind": "vegan", "name_de": "Kichererbsen-Curry",
                        "name_en": "Chickpea curry", "ingredients_de": ["Kichererbsen", "Tomaten"],
                        "ingredients_en": ["Chickpeas", "Tomatoes"], "milk": null, "egg": null
                      }
                    ]
                  }
                ]
              },
              "menu_error": null
            },
            {
              "id": "c4a7e1f0-0000-4c1a-8f30-2b7e5c918d82",
              "received_at": "2026-08-24T07:45:00.123456+00:00",
              "link": null,
              "attachments": [
                {
                  "id": "a3", "filename": "Speiseplan_KW35.pdf", "content_type": "application/pdf",
                  "size": 90311, "language": null
                }
              ],
              "menu": null,
              "menu_error": "The PDF has no readable menu table."
            }
          ]
        }
        """#
}
