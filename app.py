from flask import Flask, jsonify, request

app = Flask(__name__)

items = []


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


@app.route("/items", methods=["GET"])
def get_items():
    return jsonify({"items": items})


@app.route("/items", methods=["POST"])
def create_item():
    data = request.get_json()
    if not data or "name" not in data:
        return jsonify({"error": "name is required"}), 400
    item = {"id": len(items) + 1, "name": data["name"]}
    items.append(item)
    return jsonify(item), 201


@app.route("/items/<int:item_id>", methods=["GET"])
def get_item(item_id):
    item = next((i for i in items if i["id"] == item_id), None)
    if item is None:
        return jsonify({"error": "item not found"}), 404
    return jsonify(item)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
