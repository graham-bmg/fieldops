import { View, Text, StyleSheet } from "react-native";
import { useTheme } from "../hooks/useTheme";

export default function DashboardScreen() {
  const { colors, spacing, typography } = useTheme();

  return (
    <View style={[styles.container, { backgroundColor: colors.background, padding: spacing.lg }]}>
      <Text style={[typography.title, { color: colors.textPrimary }]}>
        FieldOps
      </Text>
      <Text style={[typography.body, { color: colors.textSecondary, marginTop: spacing.xs }]}>
        Dashboard
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    justifyContent: "center",
  },
});