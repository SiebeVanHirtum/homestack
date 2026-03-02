<?php
$config_dir = 'device_configs/';
// Scan de map voor .json bestanden
$available_configs = glob($config_dir . "*.json");

if ($_SERVER["REQUEST_METHOD"] == "POST") {
    $selected_model_file = $_POST['model'];
    
    if (file_exists($selected_model_file)) {
        // 1. Lees de gekozen device_config in
        $device_config_json = file_get_contents($selected_model_file);
        $device_config = json_decode($device_config_json, true);

        // 2. Verzamel user_input
        $user_input = [
            "device_ip"     => $_POST['ip'],
            "device_id"     => $_POST['id'],
            "friendly_name" => $_POST['name'],
            "mqtt_server"   => "10.3.141.1:1883",
            "mqtt_user"     => "siebe",
            "mqtt_pass"     => "2250"
        ];

        $data_to_send = [
            "user_input" => $user_input,
            "device_config" => $device_config
        ];

        // 3. Verstuur naar Node-RED
        $url = "http://10.3.141.1:1880/add-device";
        $ch = curl_init($url);
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data_to_send));
        curl_setopt($ch, CURLOPT_HTTPHEADER, array('Content-Type:application/json'));
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        $result = curl_exec($ch);

        // curl_close() is verwijderd om de deprecation warning in PHP 8.0+ te voorkomen
        echo "<div style='color: green;'><h3>Resultaat: " . htmlspecialchars($result) . "</h3></div>";
    }
}
?>

<!DOCTYPE html>
<html lang="nl">
<head><title>Device Manager</title></head>
<body>
    <h2>Nieuw Apparaat Toevoegen</h2>
    <form method="post">
        Model: 
        <select name="model" required>
            <?php foreach ($available_configs as $file): ?>
                <option value="<?php echo $file; ?>">
                    <?php echo str_replace([$config_dir, '.json'], '', $file); ?>
                </option>
            <?php endforeach; ?>
        </select><br><br>

        IP Adres: <input type="text" name="ip" value="10.3.141.1" required><br>
        Device ID: <input type="text" name="id" value="shellyplug-s-01" required><br>
        Naam: <input type="text" name="name" value="Wasmachine Plug" required><br><br>

        <button type="submit">Configureer en Voeg toe aan Home Assistant</button>
    </form>
</body>
</html>
