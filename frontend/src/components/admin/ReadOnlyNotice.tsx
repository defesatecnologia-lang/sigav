import { Alert } from "@mantine/core";
import { TbEye } from "react-icons/tb";
import { FormattedMessage } from "react-intl";

/**
 * Aviso exibido ao auditor nas telas administrativas: ele pode inspecionar
 * tudo, mas nenhuma ação de escrita está disponível.
 */
const ReadOnlyNotice = () => (
  <Alert
    color="blue"
    variant="light"
    icon={<TbEye size={18} />}
    mb="md"
  >
    <FormattedMessage id="admin.readOnly.notice" />
  </Alert>
);

export default ReadOnlyNotice;
