export interface ConfigFile {
  id: string;
  name: string;
  content: string;
  createdAt: number;
  updatedAt: number;
}

export interface ConfigFileInput {
  name: string;
  content: string;
}
