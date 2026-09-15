#ifndef CHRNET_CORE_JSON_H_
#define CHRNET_CORE_JSON_H_

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace chrnet {

struct JsonMember;

// A small JSON document model. It carries the pipe protocol between the app and
// the ChrNet service and reads Xray's metrics output. Neither needs more than
// objects, arrays, strings, booleans and integers, so a number keeps an exact
// int64 next to its double value.
class JsonValue {
 public:
  enum class Type { kNull, kBool, kNumber, kString, kArray, kObject };

  JsonValue();
  JsonValue(const JsonValue& other);
  JsonValue(JsonValue&& other) noexcept;
  JsonValue& operator=(const JsonValue& other);
  JsonValue& operator=(JsonValue&& other) noexcept;
  ~JsonValue();

  static JsonValue MakeBool(bool value);
  static JsonValue MakeInt(int64_t value);
  static JsonValue MakeDouble(double value);
  static JsonValue MakeString(std::string value);
  static JsonValue MakeArray();
  static JsonValue MakeObject();
  static JsonValue MakeStringArray(const std::vector<std::string>& values);

  // Returns nothing for malformed input, trailing garbage or nesting deeper
  // than 64 levels.
  static std::optional<JsonValue> Parse(std::string_view text);

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::kNull; }
  bool is_bool() const { return type_ == Type::kBool; }
  bool is_number() const { return type_ == Type::kNumber; }
  bool is_string() const { return type_ == Type::kString; }
  bool is_array() const { return type_ == Type::kArray; }
  bool is_object() const { return type_ == Type::kObject; }

  bool GetBool(bool fallback = false) const;
  int64_t GetInt(int64_t fallback = 0) const;
  double GetDouble(double fallback = 0) const;
  // Empty for anything that is not a string.
  const std::string& GetString() const;

  const std::vector<JsonValue>& items() const { return items_; }
  const std::vector<JsonMember>& members() const { return members_; }

  // nullptr when this is not an object or the key is absent.
  const JsonValue* Find(std::string_view key) const;
  std::string GetStringMember(std::string_view key,
                              const std::string& fallback = {}) const;
  bool GetBoolMember(std::string_view key, bool fallback = false) const;
  int64_t GetIntMember(std::string_view key, int64_t fallback = 0) const;
  // String entries of an array member; other entries are skipped.
  std::vector<std::string> GetStringArrayMember(std::string_view key) const;

  // Both turn a null value into an object or array first. Set replaces an
  // existing member of the same name.
  JsonValue& Set(std::string key, JsonValue value);
  JsonValue& SetString(std::string key, std::string value);
  JsonValue& SetBool(std::string key, bool value);
  JsonValue& SetInt(std::string key, int64_t value);
  void Push(JsonValue value);

  std::string Serialize() const;

 private:
  Type type_ = Type::kNull;
  bool bool_ = false;
  bool is_int_ = false;
  int64_t int_ = 0;
  double double_ = 0;
  std::string string_;
  std::vector<JsonValue> items_;
  std::vector<JsonMember> members_;

  friend class JsonParser;
};

struct JsonMember {
  std::string key;
  JsonValue value;
};

}  // namespace chrnet

#endif  // CHRNET_CORE_JSON_H_
